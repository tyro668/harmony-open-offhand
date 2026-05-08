import { common } from '@kit.AbilityKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import {
  OfflineRecognizer,
  OfflineRecognizerConfig,
  SileroVadConfig,
  TenVadConfig,
  Vad,
  VadConfig
} from 'sherpa_onnx';
import type { SpeechSegment } from 'sherpa_onnx';
import { OffhandVoiceConfig, VoiceRecognitionResult } from '../common/ImeTypes';
import { AsrListener, AsrProvider } from './AsrProvider';
import { SenseVoiceModelInstaller, SenseVoiceModelPaths } from './SenseVoiceModelInstaller';

const DOMAIN = 0xFF10;
const TAG = 'SenseVoiceLocalAsr';

export const SENSEVOICE_DEFAULT_CAPTURE_SAMPLE_RATE = 16000;
const SENSEVOICE_MODEL_SAMPLE_RATE = 16000;
// SenseVoice is an offline short-audio recognizer. Feeding a whole minute-plus
// recording into one stream can exceed the model/runtime's stable context.
const SENSEVOICE_MAX_DECODE_SECONDS = 25;
const SENSEVOICE_MAX_DECODE_SAMPLES = SENSEVOICE_MODEL_SAMPLE_RATE * SENSEVOICE_MAX_DECODE_SECONDS;
const SENSEVOICE_MIN_DECODE_SAMPLES = Math.round(SENSEVOICE_MODEL_SAMPLE_RATE * 0.2);
const SENSEVOICE_VAD_THRESHOLD = 0.5;
const SENSEVOICE_VAD_MIN_SPEECH_SECONDS = 0.25;
const SENSEVOICE_VAD_MIN_SILENCE_SECONDS = 0.5;
const SENSEVOICE_VAD_WINDOW_SIZE = 512;
const SENSEVOICE_VAD_MAX_SPEECH_SECONDS = 20;
const SENSEVOICE_VAD_BUFFER_SECONDS = 90;
const SENSEVOICE_VAD_FEED_SECONDS = 1;
const SENSEVOICE_VAD_FEED_SAMPLES = SENSEVOICE_MODEL_SAMPLE_RATE * SENSEVOICE_VAD_FEED_SECONDS;

export class SenseVoiceLocalAsrProvider implements AsrProvider {
  readonly id: string = 'sensevoice_local';

  private readonly installer: SenseVoiceModelInstaller = new SenseVoiceModelInstaller();
  private context?: common.Context;
  private listener?: AsrListener;
  private recognizer?: OfflineRecognizer;
  private modelPaths?: SenseVoiceModelPaths;
  private active: boolean = false;
  private captureSampleRate: number = SENSEVOICE_DEFAULT_CAPTURE_SAMPLE_RATE;
  private unavailableReason: string = '';
  private framesReceived: number = 0;
  private resampledSamplesReceived: number = 0;
  private bufferedSampleCount: number = 0;
  private lastStatsLogAtMs: number = 0;
  private bufferedSampleChunks: Float32Array[] = [];
  private resamplerBuffer: number[] = [];
  private resamplerInputIndex: number = 0;

  constructor(context?: common.Context) {
    this.context = context;
  }

  setContext(context?: common.Context): void {
    this.context = context;
  }

  setCaptureSampleRate(sampleRate: number): void {
    if (sampleRate > 0) {
      this.captureSampleRate = sampleRate;
    }
  }

  getUnavailableReason(): string {
    return this.unavailableReason;
  }

  async isAvailable(config: OffhandVoiceConfig, locale: string): Promise<boolean> {
    this.unavailableReason = '';
    if (!config.localAsr.enabled) {
      this.unavailableReason = 'local ASR disabled';
      return false;
    }
    if (!this.isLocaleSupported(locale)) {
      this.unavailableReason = `locale ${locale} is not supported by SenseVoice`;
      return false;
    }
    if (!this.context) {
      this.unavailableReason = 'runtime context unavailable';
      return false;
    }
    let modelPaths = await this.installer.ensureReady(this.context, config.localAsr);
    if (!modelPaths) {
      this.unavailableReason = 'bundled SenseVoice model files are missing or invalid';
      return false;
    }
    return true;
  }

  async start(config: OffhandVoiceConfig, locale: string, listener: AsrListener): Promise<void> {
    if (!this.context) {
      throw new Error('local ASR context unavailable');
    }
    // ensureReady 已在 isAvailable() 中调用过，此处直接复用缓存结果
    let modelPaths = await this.installer.ensureReady(this.context, config.localAsr);
    if (!modelPaths) {
      throw new Error('local ASR model is not ready');
    }

    this.listener = listener;
    this.active = true;
    this.modelPaths = modelPaths;
    this.captureSampleRate = resolveSenseVoiceCaptureSampleRate(config);
    this.resetSessionState();

    await this.initRecognizer(config, locale, modelPaths);
    hilog.info(DOMAIN, TAG,
      'starting local ASR modelDir=%{public}s rawfileMode=%{public}s captureSampleRate=%{public}d',
      modelPaths.modelDir, String(modelPaths.resourceManager !== undefined), this.captureSampleRate);
  }

  pushAudioFrame(frame: Uint8Array): void {
    if (!this.active || !this.recognizer) {
      return;
    }
    let captureSamples = pcm16leToFloat32(frame);
    if (captureSamples.length === 0) {
      return;
    }

    this.framesReceived += captureSamples.length;
    let samples = this.resampleToModelSampleRate(captureSamples);
    if (samples.length === 0) {
      this.logRuntimeStatsIfNeeded();
      return;
    }

    this.resampledSamplesReceived += samples.length;
    this.appendBufferedSamples(samples);
    this.logRuntimeStatsIfNeeded();
  }

  async stop(discardResult: boolean): Promise<VoiceRecognitionResult> {
    let text = '';
    let startedAt = Date.now();
    if (this.active && this.recognizer) {
      try {
        let samples = this.collectBufferedSamples();
        if (!discardResult && samples.length > 0) {
          text = this.decodeLongSamples(samples);
          if (text.length > 0) {
            this.listener?.onFinal(text);
          }
        }
        hilog.info(DOMAIN, TAG,
          'local ASR final len=%{public}d bufferedSamples=%{public}d latencyMs=%{public}d',
          text.length, this.bufferedSampleCount, Date.now() - startedAt);
      } catch (error) {
        let message = (error as Error).message ?? String(error);
        hilog.warn(DOMAIN, TAG, 'offline decode failed: %{public}s', message);
        this.listener?.onError(message);
      }
    }

    await this.destroy();
    return {
      text: discardResult ? '' : text,
      source: 'sensevoice_local'
    };
  }

  async destroy(): Promise<void> {
    this.active = false;
    this.recognizer = undefined;
    this.modelPaths = undefined;
    this.listener = undefined;
    this.resetSessionState();
  }

  private async initRecognizer(config: OffhandVoiceConfig, locale: string,
    paths: SenseVoiceModelPaths): Promise<void> {
    let recognizerConfig = new OfflineRecognizerConfig();
    recognizerConfig.featConfig.sampleRate = SENSEVOICE_MODEL_SAMPLE_RATE;
    recognizerConfig.featConfig.featureDim = 80;
    recognizerConfig.modelConfig.senseVoice.model = paths.modelPath;
    recognizerConfig.modelConfig.senseVoice.language = resolveSenseVoiceLanguage(locale);
    recognizerConfig.modelConfig.senseVoice.useItn = true;
    recognizerConfig.modelConfig.tokens = paths.tokensPath;
    recognizerConfig.modelConfig.numThreads = clamp(config.localAsr.numThreads, 1, 2);
    recognizerConfig.modelConfig.provider = 'cpu';
    recognizerConfig.modelConfig.debug = true;
    recognizerConfig.decodingMethod = config.localAsr.decodingMethod;
    recognizerConfig.maxActivePaths = clamp(config.localAsr.maxActivePaths, 1, 8);

    this.recognizer = new OfflineRecognizer(recognizerConfig, paths.resourceManager);
    hilog.info(DOMAIN, TAG,
      'recognizer created handle=%{public}s debug=%{public}s',
      String(typeof this.recognizer.handle), String(recognizerConfig.modelConfig.debug));
  }

  private decodeSamples(samples: Float32Array): string {
    if (!this.recognizer || samples.length === 0) {
      return '';
    }

    let stream = this.recognizer.createStream();
    stream.acceptWaveform({
      samples: samples,
      sampleRate: SENSEVOICE_MODEL_SAMPLE_RATE
    });
    this.recognizer.decode(stream);
    let result = this.recognizer.getResult(stream);
    hilog.info(DOMAIN, TAG,
      'decode result sampleCount=%{public}d text="%{public}s" lang=%{public}s emotion=%{public}s event=%{public}s json=%{public}s',
      samples.length, result.text, result.lang, result.emotion, result.event,
      typeof result.json === 'string' ? (result.json as string).substring(0, 200) : '');
    return sanitizeTranscript(result.text);
  }

  private decodeLongSamples(samples: Float32Array): string {
    let chunks = this.splitDecodeChunksWithVad(samples);
    let transcripts: string[] = [];
    hilog.info(DOMAIN, TAG,
      'decoding SenseVoice input totalSamples=%{public}d chunks=%{public}d',
      samples.length, chunks.length);
    for (let index = 0; index < chunks.length; index++) {
      let chunk = chunks[index];
      let transcript = this.decodeSamples(chunk);
      if (transcript.length > 0) {
        transcripts.push(transcript);
      }
      hilog.info(DOMAIN, TAG,
        'long decode chunk=%{public}d/%{public}d sampleCount=%{public}d textLen=%{public}d',
        index + 1, chunks.length, chunk.length, transcript.length);
    }
    return joinTranscriptSegments(transcripts);
  }

  private splitDecodeChunksWithVad(samples: Float32Array): Float32Array[] {
    let vadChunks = this.trySplitDecodeChunksWithSileroVad(samples);
    if (vadChunks.length > 0) {
      return vadChunks;
    }
    let fallbackChunks = splitDecodeChunks(samples);
    hilog.info(DOMAIN, TAG,
      'using fixed decode chunks totalSamples=%{public}d chunkSamples=%{public}d chunks=%{public}d',
      samples.length, SENSEVOICE_MAX_DECODE_SAMPLES, fallbackChunks.length);
    return fallbackChunks;
  }

  private trySplitDecodeChunksWithSileroVad(samples: Float32Array): Float32Array[] {
    let paths = this.modelPaths;
    if (!paths || !paths.resourceManager) {
      hilog.warn(DOMAIN, TAG, 'Silero VAD skipped: model paths unavailable');
      return [];
    }

    try {
      let vadConfig = new VadConfig(
        new SileroVadConfig(
          paths.vadModelPath,
          SENSEVOICE_VAD_THRESHOLD,
          SENSEVOICE_VAD_MIN_SPEECH_SECONDS,
          SENSEVOICE_VAD_MIN_SILENCE_SECONDS,
          SENSEVOICE_VAD_WINDOW_SIZE,
          SENSEVOICE_VAD_MAX_SPEECH_SECONDS
        ),
        new TenVadConfig('', 0, 0, 0, 0, 0),
        SENSEVOICE_MODEL_SAMPLE_RATE,
        false,
        1,
        'cpu'
      );
      let vad = new Vad(vadConfig, SENSEVOICE_VAD_BUFFER_SECONDS, paths.resourceManager);
      let speechSegments = collectSileroVadSpeechSegments(vad, samples);
      if (speechSegments.length === 0) {
        hilog.warn(DOMAIN, TAG,
          'Silero VAD found no speech segments totalSamples=%{public}d', samples.length);
        return [];
      }

      let chunks: Float32Array[] = [];
      for (let index = 0; index < speechSegments.length; index++) {
        let segment = speechSegments[index];
        appendDecodeChunks(chunks, segment);
      }
      hilog.info(DOMAIN, TAG,
        'Silero VAD split totalSamples=%{public}d speechSegments=%{public}d decodeChunks=%{public}d',
        samples.length, speechSegments.length, chunks.length);
      return chunks;
    } catch (error) {
      hilog.warn(DOMAIN, TAG, 'Silero VAD split failed: %{public}s',
        (error as Error).message ?? String(error));
      return [];
    }
  }

  private appendBufferedSamples(samples: Float32Array): void {
    if (samples.length === 0) {
      return;
    }
    this.bufferedSampleChunks.push(samples);
    this.bufferedSampleCount += samples.length;
  }

  private collectBufferedSamples(): Float32Array {
    if (this.bufferedSampleCount === 0) {
      return new Float32Array(0);
    }

    let samples = new Float32Array(this.bufferedSampleCount);
    let offset = 0;
    for (let index = 0; index < this.bufferedSampleChunks.length; index++) {
      let chunk = this.bufferedSampleChunks[index];
      samples.set(chunk, offset);
      offset += chunk.length;
    }
    return samples;
  }

  private resampleToModelSampleRate(samples: Float32Array): Float32Array {
    if (samples.length === 0) {
      return new Float32Array(0);
    }
    if (this.captureSampleRate === SENSEVOICE_MODEL_SAMPLE_RATE) {
      return samples;
    }

    for (let index = 0; index < samples.length; index++) {
      this.resamplerBuffer.push(samples[index]);
    }

    let step = this.captureSampleRate / SENSEVOICE_MODEL_SAMPLE_RATE;
    let output: number[] = [];
    while (this.resamplerInputIndex + 1 < this.resamplerBuffer.length) {
      let baseIndex = Math.floor(this.resamplerInputIndex);
      let nextIndex = baseIndex + 1;
      let weight = this.resamplerInputIndex - baseIndex;
      let left = this.resamplerBuffer[baseIndex];
      let right = this.resamplerBuffer[nextIndex];
      output.push(left + ((right - left) * weight));
      this.resamplerInputIndex += step;
    }

    let consumedSourceSamples = Math.floor(this.resamplerInputIndex);
    if (consumedSourceSamples > 0) {
      this.resamplerBuffer = this.resamplerBuffer.slice(consumedSourceSamples);
      this.resamplerInputIndex -= consumedSourceSamples;
    }

    let resampled = new Float32Array(output.length);
    for (let index = 0; index < output.length; index++) {
      resampled[index] = output[index];
    }
    return resampled;
  }

  private resetSessionState(): void {
    this.framesReceived = 0;
    this.resampledSamplesReceived = 0;
    this.bufferedSampleCount = 0;
    this.lastStatsLogAtMs = 0;
    this.bufferedSampleChunks = [];
    this.resamplerBuffer = [];
    this.resamplerInputIndex = 0;
  }

  private logRuntimeStatsIfNeeded(): void {
    let now = Date.now();
    if (now - this.lastStatsLogAtMs < 1000) {
      return;
    }
    this.lastStatsLogAtMs = now;
    hilog.info(DOMAIN, TAG,
      'local ASR captureSamples=%{public}d resampledSamples=%{public}d bufferedSamples=%{public}d captureSampleRate=%{public}d',
      this.framesReceived, this.resampledSamplesReceived, this.bufferedSampleCount,
      this.captureSampleRate);
  }

  private isLocaleSupported(locale: string): boolean {
    let normalized = locale.toLowerCase();
    return normalized.startsWith('zh') || normalized.startsWith('en') || normalized.startsWith('ja') ||
      normalized.startsWith('ko') || normalized.startsWith('yue');
  }
}

function resolveSenseVoiceLanguage(locale: string): string {
  let normalized = locale.toLowerCase();
  if (normalized.startsWith('en')) {
    return 'en';
  }
  if (normalized.startsWith('ja')) {
    return 'ja';
  }
  if (normalized.startsWith('ko')) {
    return 'ko';
  }
  if (normalized.startsWith('yue')) {
    return 'yue';
  }
  if (normalized.startsWith('zh')) {
    return 'zh';
  }
  return 'auto';
}

function sanitizeTranscript(text: string): string {
  return text.replace(/[\u0000-\u001f\u007f]/g, ' ').replace(/\s+/g, ' ').trim();
}

function collectSileroVadSpeechSegments(vad: Vad, samples: Float32Array): Float32Array[] {
  let segments: Float32Array[] = [];
  let offset = 0;
  while (offset < samples.length) {
    let end = Math.min(offset + SENSEVOICE_VAD_FEED_SAMPLES, samples.length);
    vad.acceptWaveform(samples.slice(offset, end));
    drainSileroVadSegments(vad, segments);
    offset = end;
  }
  vad.flush();
  drainSileroVadSegments(vad, segments);
  return segments;
}

function drainSileroVadSegments(vad: Vad, segments: Float32Array[]): void {
  while (!vad.isEmpty()) {
    let segment: SpeechSegment = vad.front(false);
    if (segment.samples.length >= SENSEVOICE_MIN_DECODE_SAMPLES) {
      segments.push(new Float32Array(segment.samples));
    }
    vad.pop();
  }
}

function appendDecodeChunks(chunks: Float32Array[], segment: Float32Array): void {
  if (segment.length < SENSEVOICE_MIN_DECODE_SAMPLES) {
    return;
  }
  let splitChunks = splitDecodeChunks(segment);
  for (let index = 0; index < splitChunks.length; index++) {
    chunks.push(splitChunks[index]);
  }
}

function splitDecodeChunks(samples: Float32Array): Float32Array[] {
  let chunks: Float32Array[] = [];
  let offset = 0;
  while (offset < samples.length) {
    let end = Math.min(offset + SENSEVOICE_MAX_DECODE_SAMPLES, samples.length);
    let chunk = samples.slice(offset, end);
    if (chunk.length >= SENSEVOICE_MIN_DECODE_SAMPLES || chunks.length === 0) {
      chunks.push(chunk);
    }
    offset = end;
  }
  return chunks;
}

function joinTranscriptSegments(segments: string[]): string {
  let result = '';
  for (let index = 0; index < segments.length; index++) {
    let segment = sanitizeTranscript(segments[index]);
    if (segment.length === 0) {
      continue;
    }
    if (result.length === 0) {
      result = segment;
      continue;
    }
    result = shouldInsertSpaceBetween(result, segment) ? `${result} ${segment}` : `${result}${segment}`;
  }
  return result;
}

function shouldInsertSpaceBetween(left: string, right: string): boolean {
  return endsWithAsciiWord(left) && startsWithAsciiWord(right);
}

function endsWithAsciiWord(text: string): boolean {
  if (text.length === 0) {
    return false;
  }
  return isAsciiWordCode(text.charCodeAt(text.length - 1));
}

function startsWithAsciiWord(text: string): boolean {
  if (text.length === 0) {
    return false;
  }
  return isAsciiWordCode(text.charCodeAt(0));
}

function isAsciiWordCode(code: number): boolean {
  return (code >= 48 && code <= 57) || (code >= 65 && code <= 90) || (code >= 97 && code <= 122);
}

function pcm16leToFloat32(frame: Uint8Array): Float32Array {
  let sampleCount = Math.floor(frame.byteLength / 2);
  let samples = new Float32Array(sampleCount);
  let view = new DataView(frame.buffer, frame.byteOffset, sampleCount * 2);
  for (let index = 0; index < sampleCount; index++) {
    samples[index] = view.getInt16(index * 2, true) / 32768.0;
  }
  return samples;
}

function clamp(value: number, min: number, max: number): number {
  if (value < min) {
    return min;
  }
  if (value > max) {
    return max;
  }
  return value;
}

export function resolveSenseVoiceCaptureSampleRate(config: OffhandVoiceConfig): number {
  let sampleRate = config.localAsr.captureSampleRate;
  if (sampleRate === 16000 || sampleRate === 44100 || sampleRate === 48000) {
    return sampleRate;
  }
  return SENSEVOICE_DEFAULT_CAPTURE_SAMPLE_RATE;
}
