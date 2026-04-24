import { common } from '@kit.AbilityKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import {
  OfflineRecognizer,
  OfflineRecognizerConfig
} from 'sherpa_onnx';
import { OffhandVoiceConfig, VoiceRecognitionResult } from '../common/ImeTypes';
import { AsrListener, AsrProvider } from './AsrProvider';
import { SenseVoiceModelInstaller, SenseVoiceModelPaths } from './SenseVoiceModelInstaller';

const DOMAIN = 0xFF10;
const TAG = 'SenseVoiceLocalAsr';

export const SENSEVOICE_DEFAULT_CAPTURE_SAMPLE_RATE = 16000;
const SENSEVOICE_MODEL_SAMPLE_RATE = 16000;

export class SenseVoiceLocalAsrProvider implements AsrProvider {
  readonly id: string = 'sensevoice_local';

  private readonly installer: SenseVoiceModelInstaller = new SenseVoiceModelInstaller();
  private context?: common.Context;
  private listener?: AsrListener;
  private recognizer?: OfflineRecognizer;
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
    let modelPaths = await this.installer.ensureReady(this.context, config.localAsr);
    if (!modelPaths) {
      throw new Error('local ASR model is not ready');
    }

    this.listener = listener;
    this.active = true;
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
          text = this.decodeSamples(samples);
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
    recognizerConfig.modelConfig.debug = false;
    recognizerConfig.decodingMethod = config.localAsr.decodingMethod;
    recognizerConfig.maxActivePaths = clamp(config.localAsr.maxActivePaths, 1, 8);

    this.recognizer = new OfflineRecognizer(recognizerConfig, paths.resourceManager);
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
    return sanitizeTranscript(result.text);
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