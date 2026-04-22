import audio from '@ohos.multimedia.audio';
import type speechRecognizer from '@hms.ai.speechRecognizer';
import { util } from '@kit.ArkTS';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { RemoteHttpClient } from '../network/RemoteHttpClient';
import { OffhandVoiceConfig, VoiceRecognitionResult } from '../common/ImeTypes';

interface VoiceSessionState {
  active: boolean;
  startedAt: number;
  chunks: Uint8Array[];
}

interface RemoteAsrPayload {
  locale: string;
  audioFormat: string;
  sampleRate: number;
  audioBase64: string;
}

const BUILTIN_ASR_FRAME_BYTES = 640;

interface SpeechRecognizerApi {
  createEngine(params: speechRecognizer.CreateEngineParams): Promise<speechRecognizer.SpeechRecognitionEngine>;
}

class BuiltinAsrListenerAdapter implements speechRecognizer.RecognitionListener {
  private readonly onTranscript: (text: string) => void;

  constructor(onTranscript: (text: string) => void) {
    this.onTranscript = onTranscript;
  }

  onStart(sessionId: string, eventMessage: string): void {
    hilog.info(0xFF10, 'VoiceCaptureService', 'builtin ASR onStart: %{public}s', eventMessage);
  }

  onResult(sessionId: string, result: speechRecognizer.SpeechRecognitionResult): void {
    hilog.info(0xFF10, 'VoiceCaptureService', 'builtin ASR onResult: %{public}s', result.result);
    this.onTranscript(result.result);
  }

  onComplete(sessionId: string, eventMessage: string): void {
    hilog.info(0xFF10, 'VoiceCaptureService', 'builtin ASR onComplete: %{public}s', eventMessage);
  }

  onError(sessionId: string, errorCode: number, errorMessage: string): void {
    hilog.error(0xFF10, 'VoiceCaptureService',
      'builtin ASR onError: %{public}d %{public}s', errorCode, errorMessage);
  }

  onEvent(sessionId: string, eventCode: number, eventMessage: string): void {
    hilog.info(0xFF10, 'VoiceCaptureService',
      'builtin ASR onEvent: %{public}d %{public}s', eventCode, eventMessage);
  }
}

export class VoiceCaptureService {
  private capturer?: audio.AudioCapturer;
  private readonly httpClient: RemoteHttpClient = new RemoteHttpClient();
  private readonly base64Helper: util.Base64Helper = new util.Base64Helper();
  private readonly state: VoiceSessionState = {
    active: false,
    startedAt: 0,
    chunks: []
  };
  private asrEngine?: speechRecognizer.SpeechRecognitionEngine;
  private asrSessionId: string = '';
  private asrResultText: string = '';
  private useBuiltinAsr: boolean = false;
  private pendingBuiltinAudio: Uint8Array = new Uint8Array(0);
  private onTranscriptUpdate?: (text: string) => void;

  private readonly onReadData = (buffer: ArrayBuffer): void => {
    if (!this.state.active) {
      return;
    }
    try {
      // 兼容不同版本的 readData 回调参数格式
      let actualBuffer: ArrayBuffer;
      if (buffer instanceof ArrayBuffer) {
        actualBuffer = buffer;
      } else {
        // 某些版本中回调参数为 { buffer: ArrayBuffer } 对象
        let obj = buffer as Object;
        let record = obj as Record<string, Object>;
        if (record.buffer instanceof ArrayBuffer) {
          actualBuffer = record.buffer as ArrayBuffer;
        } else {
          return;
        }
      }
      let uint8Buffer = new Uint8Array(actualBuffer);
      this.state.chunks.push(uint8Buffer);
      if (this.useBuiltinAsr && this.asrEngine) {
        this.enqueueBuiltinAsrAudio(uint8Buffer);
      }
    } catch (error) {
      hilog.error(0xFF10, 'VoiceCaptureService', 'readData callback error: %{public}s',
        (error as Error).message ?? String(error));
    }
  };

  async start(config: OffhandVoiceConfig, locale: string): Promise<void> {
    if (this.state.active) {
      hilog.warn(0xFF10, 'VoiceCaptureService', 'start called but already active');
      return;
    }
    this.resetChunks();
    this.asrResultText = '';
    this.useBuiltinAsr = false;
    this.pendingBuiltinAudio = new Uint8Array(0);

    let sampleRate = resolveSampleRate(config.sampleRate);

    // 未配置远程 ASR 且当前语言为中文时，尝试使用系统内置 ASR
    if (config.asrEndpoint.length === 0 && this.isLocaleSupportedByBuiltinAsr(locale)) {
      try {
        await this.initBuiltinAsr(config, locale);
        this.useBuiltinAsr = true;
        hilog.info(0xFF10, 'VoiceCaptureService', 'builtin ASR initialized for %{public}s', locale);
      } catch (error) {
        let errorMsg = (error as Error).message ?? String(error);
        hilog.error(0xFF10, 'VoiceCaptureService', 'builtin ASR unavailable: %{public}s', errorMsg);
        throw new Error(`系统 ASR 初始化失败: ${errorMsg}`);
      }
    } else if (config.asrEndpoint.length === 0) {
      hilog.info(0xFF10, 'VoiceCaptureService',
        'locale %{public}s not supported by builtin ASR, will use mock/remote', locale);
    }

    hilog.info(0xFF10, 'VoiceCaptureService',
      'creating AudioCapturer with sampleRate=%{public}d', config.sampleRate);
    try {
      this.capturer = await this.createCapturerWithFallback(sampleRate);
    } catch (error) {
      let errorMsg = (error as Error).message ?? String(error);
      hilog.error(0xFF10, 'VoiceCaptureService', 'createAudioCapturer failed: %{public}s', errorMsg);
      this.shutdownBuiltinAsr();
      throw new Error(
        `音频录制初始化失败(${errorMsg})，鸿蒙模拟器不支持麦克风，请在真机上测试。`);
    }
    this.capturer.on('readData', this.onReadData);
    hilog.info(0xFF10, 'VoiceCaptureService', 'starting AudioCapturer...');
    try {
      await this.capturer.start();
    } catch (error) {
      let errorMsg = (error as Error).message ?? String(error);
      hilog.error(0xFF10, 'VoiceCaptureService', 'capturer.start failed: %{public}s', errorMsg);
      this.capturer.off('readData', this.onReadData);
      await this.capturer.release();
      this.capturer = undefined;
      this.shutdownBuiltinAsr();
      throw new Error(errorMsg);
    }
    this.state.active = true;
    this.state.startedAt = Date.now();
    hilog.info(0xFF10, 'VoiceCaptureService', 'AudioCapturer started successfully');
  }

  async stop(config: OffhandVoiceConfig, locale: string): Promise<VoiceRecognitionResult> {
    if (!this.state.active || !this.capturer) {
      return this.resolveBuiltinAsrResult(config);
    }
    let capturer = this.capturer;
    this.state.active = false;
    try {
      await capturer.stop();
    } catch (error) {
      hilog.warn(0xFF10, 'VoiceCaptureService', 'capturer.stop warning: %{public}s',
        (error as Error).message ?? String(error));
    }
    try {
      capturer.off('readData', this.onReadData);
    } catch (error) {
      hilog.warn(0xFF10, 'VoiceCaptureService', 'capturer.off warning: %{public}s',
        (error as Error).message ?? String(error));
    }
    try {
      await capturer.release();
    } catch (error) {
      hilog.warn(0xFF10, 'VoiceCaptureService', 'capturer.release warning: %{public}s',
        (error as Error).message ?? String(error));
    }
    this.capturer = undefined;

    // 使用内置 ASR
    if (this.useBuiltinAsr && this.asrEngine) {
      try {
        this.flushBuiltinAsrAudio();
        this.asrEngine.finish(this.asrSessionId);
        // 等待 ASR 引擎返回最终结果
        await new Promise<void>(resolve => setTimeout(resolve, 1500));
      } catch (error) {
        hilog.warn(0xFF10, 'VoiceCaptureService', 'builtin ASR finish error: %{public}s',
          (error as Error).message ?? String(error));
      }
      return this.resolveBuiltinAsrResult(config);
    }

    // 远程 ASR 或 mock
    let pcmData = mergeChunks(this.state.chunks);
    this.resetChunks();
    if (config.asrEndpoint.length > 0 && pcmData.byteLength > 0) {
      try {
        let wavData = wrapPcmAsWav(pcmData, config.sampleRate, 1, 16);
        let payload: RemoteAsrPayload = {
          locale: locale,
          audioFormat: 'wav',
          sampleRate: config.sampleRate,
          audioBase64: this.base64Helper.encodeToStringSync(new Uint8Array(wavData))
        };
        let response = await this.httpClient.postJson(config.asrEndpoint, payload, {
          timeoutMs: config.requestTimeoutMs,
          headers: createAuthorizationHeaders(config.apiKey)
        });
        let transcript = extractTranscript(response);
        if (transcript.length > 0) {
          return {
            text: transcript,
            source: 'remote_asr'
          };
        }
      } catch (_) {
      }
    }
    return {
      text: config.mockTranscript,
      source: 'mock'
    };
  }

  isRecording(): boolean {
    return this.state.active;
  }

  getRecordingDurationMs(): number {
    if (!this.state.active) {
      return 0;
    }
    return Date.now() - this.state.startedAt;
  }

  setTranscriptListener(callback?: (text: string) => void): void {
    this.onTranscriptUpdate = callback;
  }

  private resetChunks(): void {
    this.state.chunks = [];
  }

  private isLocaleSupportedByBuiltinAsr(locale: string): boolean {
    // 系统内置 ASR 目前仅支持中文普通话
    return locale.startsWith('zh');
  }

  private resolveBuiltinAsrCreateEngineCandidates(locale: string): speechRecognizer.CreateEngineParams[] {
    let languageCandidates: string[] = [];
    let normalizedLocale = locale.trim();
    this.appendBuiltinAsrLanguageCandidate(languageCandidates, normalizedLocale);
    this.appendBuiltinAsrLanguageCandidate(languageCandidates, normalizedLocale.replace(/-/g, '_'));
    this.appendBuiltinAsrLanguageCandidate(languageCandidates, normalizedLocale.replace(/_/g, '-'));
    let languageRoot = normalizedLocale.split(/[-_]/)[0];
    this.appendBuiltinAsrLanguageCandidate(languageCandidates, languageRoot);
    if (normalizedLocale.startsWith('zh')) {
      this.appendBuiltinAsrLanguageCandidate(languageCandidates, 'zh_CN');
      this.appendBuiltinAsrLanguageCandidate(languageCandidates, 'zh-CN');
      this.appendBuiltinAsrLanguageCandidate(languageCandidates, 'zh');
    }

    let candidates: speechRecognizer.CreateEngineParams[] = [];
    for (let index = 0; index < languageCandidates.length; index++) {
      candidates.push({ language: languageCandidates[index], online: 0 });
    }
    for (let index = 0; index < languageCandidates.length; index++) {
      candidates.push({ language: languageCandidates[index], online: 1 });
    }
    return candidates;
  }

  private appendBuiltinAsrLanguageCandidate(candidates: string[], language: string): void {
    if (language.length === 0 || candidates.indexOf(language) >= 0) {
      return;
    }
    candidates.push(language);
  }

  private async loadSpeechRecognizerApi(): Promise<SpeechRecognizerApi> {
    let coreSpeechKitModule = await import('@kit.CoreSpeechKit');
    let recognizerApi = this.extractSpeechRecognizerApi(coreSpeechKitModule as Object);
    if (recognizerApi) {
      return recognizerApi;
    }
    let directModule = await import('@hms.ai.speechRecognizer');
    recognizerApi = this.extractSpeechRecognizerApi(directModule as Object);
    if (recognizerApi) {
      return recognizerApi;
    }
    throw new Error('speechRecognizer export not found in CoreSpeechKit or @hms.ai.speechRecognizer');
  }

  private extractSpeechRecognizerApi(moduleObject: Object): SpeechRecognizerApi | undefined {
    let directApi = this.asSpeechRecognizerApi(moduleObject);
    if (directApi) {
      return directApi;
    }
    let moduleRecord = moduleObject as Record<string, Object>;
    let namedApi = this.asSpeechRecognizerApi(moduleRecord.speechRecognizer);
    if (namedApi) {
      return namedApi;
    }
    let defaultExport = moduleRecord.default;
    let defaultApi = this.asSpeechRecognizerApi(defaultExport);
    if (defaultApi) {
      return defaultApi;
    }
    if (defaultExport) {
      let defaultRecord = defaultExport as Record<string, Object>;
      let nestedNamedApi = this.asSpeechRecognizerApi(defaultRecord.speechRecognizer);
      if (nestedNamedApi) {
        return nestedNamedApi;
      }
    }
    return undefined;
  }

  private asSpeechRecognizerApi(candidate?: Object): SpeechRecognizerApi | undefined {
    if (!candidate) {
      return undefined;
    }
    let recognizerApi = candidate as SpeechRecognizerApi;
    if (typeof recognizerApi.createEngine === 'function') {
      return recognizerApi;
    }
    return undefined;
  }

  private async initBuiltinAsr(config: OffhandVoiceConfig, locale: string): Promise<void> {
    // 动态导入 @kit.CoreSpeechKit，避免在旧设备上因模块不存在导致启动崩溃
    try {
      let recognizerApi = await this.loadSpeechRecognizerApi();
      let createEngineCandidates = this.resolveBuiltinAsrCreateEngineCandidates(locale);
      let createEngineErrors: string[] = [];
      for (let index = 0; index < createEngineCandidates.length; index++) {
        let createEngineParams = createEngineCandidates[index];
        try {
          hilog.info(0xFF10, 'VoiceCaptureService',
            'trying builtin ASR createEngine language=%{public}s online=%{public}d',
            createEngineParams.language, createEngineParams.online);
          this.asrEngine = await recognizerApi.createEngine(createEngineParams);
          break;
        } catch (error) {
          let errorMsg = (error as Error).message ?? String(error);
          createEngineErrors.push(`${createEngineParams.language}/${createEngineParams.online}:${errorMsg}`);
          hilog.warn(0xFF10, 'VoiceCaptureService',
            'builtin ASR createEngine failed language=%{public}s online=%{public}d: %{public}s',
            createEngineParams.language, createEngineParams.online, errorMsg);
        }
      }
      if (!this.asrEngine) {
        throw new Error(`createEngine failed: ${createEngineErrors.join(' | ')}`);
      }
      this.asrSessionId = `voice-${Date.now()}`;
      this.asrResultText = '';

      let listener: speechRecognizer.RecognitionListener = new BuiltinAsrListenerAdapter((text: string): void => {
        this.asrResultText = text;
        if (this.onTranscriptUpdate) {
          this.onTranscriptUpdate(text);
        }
      });
      this.asrEngine.setListener(listener);

      let audioInfo: speechRecognizer.AudioInfo = {
        audioType: 'pcm',
        sampleRate: config.sampleRate,
        soundChannel: 1,
        sampleBit: 16
      };
      let startParams: speechRecognizer.StartParams = {
        sessionId: this.asrSessionId,
        audioInfo: audioInfo
      };
      await this.asrEngine.startListening(startParams);
    } catch (error) {
      throw new Error(`SpeechRecognizer unavailable: ${(error as Error).message ?? String(error)}`);
    }
  }

  private resolveBuiltinAsrResult(config: OffhandVoiceConfig): VoiceRecognitionResult {
    let result = this.asrResultText;
    this.shutdownBuiltinAsr();
    if (result.length > 0) {
      return { text: result, source: 'builtin_asr' };
    }
    return { text: '', source: 'builtin_asr' };
  }

  private shutdownBuiltinAsr(): void {
    try {
      this.asrEngine?.shutdown?.();
    } catch (_) {
    }
    this.asrEngine = undefined;
    this.useBuiltinAsr = false;
    this.pendingBuiltinAudio = new Uint8Array(0);
    this.onTranscriptUpdate = undefined;
  }

  private enqueueBuiltinAsrAudio(chunk: Uint8Array): void {
    this.pendingBuiltinAudio = concatUint8Arrays(this.pendingBuiltinAudio, chunk);
    while (this.pendingBuiltinAudio.byteLength >= BUILTIN_ASR_FRAME_BYTES) {
      let frame = this.pendingBuiltinAudio.slice(0, BUILTIN_ASR_FRAME_BYTES);
      this.asrEngine?.writeAudio(this.asrSessionId, frame);
      this.pendingBuiltinAudio = this.pendingBuiltinAudio.slice(BUILTIN_ASR_FRAME_BYTES);
    }
  }

  private flushBuiltinAsrAudio(): void {
    if (this.pendingBuiltinAudio.byteLength === 0) {
      return;
    }
    let paddedFrame = new Uint8Array(BUILTIN_ASR_FRAME_BYTES);
    paddedFrame.set(this.pendingBuiltinAudio, 0);
    this.asrEngine?.writeAudio(this.asrSessionId, paddedFrame);
    this.pendingBuiltinAudio = new Uint8Array(0);
  }

  private async createCapturerWithFallback(sampleRate: audio.AudioSamplingRate): Promise<audio.AudioCapturer> {
    // 优先使用 SOURCE_TYPE_MIC，SOURCE_TYPE_VOICE_RECOGNITION 在某些设备上限制录音时长
    try {
      return await this.createCapturer(sampleRate, audio.SourceType.SOURCE_TYPE_MIC);
    } catch (_) {
      return await this.createCapturer(sampleRate, audio.SourceType.SOURCE_TYPE_VOICE_RECOGNITION);
    }
  }

  private async createCapturer(sampleRate: audio.AudioSamplingRate, source: audio.SourceType): Promise<audio.AudioCapturer> {
    let streamInfo: audio.AudioStreamInfo = {
      samplingRate: sampleRate,
      channels: audio.AudioChannel.CHANNEL_1,
      sampleFormat: audio.AudioSampleFormat.SAMPLE_FORMAT_S16LE,
      encodingType: audio.AudioEncodingType.ENCODING_TYPE_RAW
    };
    let capturerInfo: audio.AudioCapturerInfo = {
      source: source,
      capturerFlags: 0
    };
    let options: audio.AudioCapturerOptions = {
      streamInfo: streamInfo,
      capturerInfo: capturerInfo
    };
    return await audio.createAudioCapturer(options);
  }
}

function createAuthorizationHeaders(apiKey?: string): Record<string, string> | undefined {
  if (!apiKey || apiKey.length === 0) {
    return undefined;
  }
  return {
    'Authorization': `Bearer ${apiKey}`
  };
}

function extractTranscript(response: Object): string {
  let payload = response as Record<string, Object | string | number | boolean | undefined>;
  if (typeof payload.text === 'string') {
    return payload.text.trim();
  }
  if (typeof payload.transcript === 'string') {
    return payload.transcript.trim();
  }
  if (typeof payload.result === 'string') {
    return payload.result.trim();
  }
  return '';
}

function mergeChunks(chunks: Uint8Array[]): Uint8Array {
  let totalLength = 0;
  for (let index = 0; index < chunks.length; index++) {
    totalLength += chunks[index].byteLength;
  }
  let merged = new Uint8Array(totalLength);
  let cursor = 0;
  for (let index = 0; index < chunks.length; index++) {
    merged.set(chunks[index], cursor);
    cursor += chunks[index].byteLength;
  }
  return merged;
}

function concatUint8Arrays(left: Uint8Array, right: Uint8Array): Uint8Array {
  if (left.byteLength === 0) {
    return right;
  }
  if (right.byteLength === 0) {
    return left;
  }
  let merged = new Uint8Array(left.byteLength + right.byteLength);
  merged.set(left, 0);
  merged.set(right, left.byteLength);
  return merged;
}

function resolveSampleRate(sampleRate: number): audio.AudioSamplingRate {
  switch (sampleRate) {
    case 8000:
      return audio.AudioSamplingRate.SAMPLE_RATE_8000;
    case 16000:
      return audio.AudioSamplingRate.SAMPLE_RATE_16000;
    case 44100:
      return audio.AudioSamplingRate.SAMPLE_RATE_44100;
    case 48000:
      return audio.AudioSamplingRate.SAMPLE_RATE_48000;
    default:
      return audio.AudioSamplingRate.SAMPLE_RATE_16000;
  }
}

function wrapPcmAsWav(pcmData: Uint8Array, sampleRate: number, channels: number, bitsPerSample: number): ArrayBuffer {
  let header = new ArrayBuffer(44);
  let view = new DataView(header);
  let byteRate = sampleRate * channels * bitsPerSample / 8;
  let blockAlign = channels * bitsPerSample / 8;
  writeAscii(view, 0, 'RIFF');
  view.setUint32(4, 36 + pcmData.byteLength, true);
  writeAscii(view, 8, 'WAVE');
  writeAscii(view, 12, 'fmt ');
  view.setUint32(16, 16, true);
  view.setUint16(20, 1, true);
  view.setUint16(22, channels, true);
  view.setUint32(24, sampleRate, true);
  view.setUint32(28, byteRate, true);
  view.setUint16(32, blockAlign, true);
  view.setUint16(34, bitsPerSample, true);
  writeAscii(view, 36, 'data');
  view.setUint32(40, pcmData.byteLength, true);

  let wav = new Uint8Array(44 + pcmData.byteLength);
  wav.set(new Uint8Array(header), 0);
  wav.set(pcmData, 44);
  return wav.buffer;
}

function writeAscii(view: DataView, offset: number, value: string): void {
  for (let index = 0; index < value.length; index++) {
    view.setUint8(offset + index, value.charCodeAt(index));
  }
}
