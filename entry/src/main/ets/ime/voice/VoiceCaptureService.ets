import { common } from '@kit.AbilityKit';
import audio from '@ohos.multimedia.audio';
import type speechRecognizer from '@hms.ai.speechRecognizer';
import { util } from '@kit.ArkTS';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { RemoteHttpClient } from '../network/RemoteHttpClient';
import { OffhandVoiceConfig, VoiceRecognitionResult } from '../common/ImeTypes';
import { AsrListener } from './AsrProvider';
import {
  resolveSenseVoiceCaptureSampleRate,
  SenseVoiceLocalAsrProvider
} from './SenseVoiceLocalAsrProvider';

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

interface Pcm16FrameStats {
  sampleCount: number;
  rms: number;
  peak: number;
}

type VoiceAsrProviderId = 'auto' | 'sensevoice_local' | 'builtin' | 'remote';

const BUILTIN_ASR_FRAME_BYTES = 640;
// HarmonyOS speechRecognizer 默认为 short-speech，单句 VAD 结束后引擎会停止接收音频。
// extraParams.recognitionMode = 1 启用长语音连续识别，避免录音只能说一句话。
const BUILTIN_ASR_RECOGNITION_MODE_LONG: number = 1;
const BUILTIN_ASR_VAD_END_SILENCE_MS: number = 2000;
const BUILTIN_ASR_MAX_AUDIO_MS: number = 60000;

interface SpeechRecognizerApi {
  createEngine(params: speechRecognizer.CreateEngineParams): Promise<speechRecognizer.SpeechRecognitionEngine>;
}

interface BuiltinAsrListenerCallbacks {
  onStart: (sessionId: string) => void;
  onResult: (result: speechRecognizer.SpeechRecognitionResult) => void;
  onComplete: (sessionId: string, eventMessage: string) => void;
  onError: (errorCode: number, errorMessage: string) => void;
  onEvent: (eventCode: number, eventMessage: string) => void;
}

class BuiltinAsrListenerAdapter implements speechRecognizer.RecognitionListener {
  private readonly callbacks: BuiltinAsrListenerCallbacks;

  constructor(callbacks: BuiltinAsrListenerCallbacks) {
    this.callbacks = callbacks;
  }

  onStart(sessionId: string, eventMessage: string): void {
    hilog.info(0xFF10, 'VoiceCaptureService', 'builtin ASR onStart: %{public}s', eventMessage);
    this.callbacks.onStart(sessionId);
  }

  onResult(sessionId: string, result: speechRecognizer.SpeechRecognitionResult): void {
    hilog.info(0xFF10, 'VoiceCaptureService',
      'builtin ASR onResult isFinal=%{public}s isLast=%{public}s text=%{public}s',
      String(result.isFinal), String(result.isLast), result.result);
    this.callbacks.onResult(result);
  }

  onComplete(sessionId: string, eventMessage: string): void {
    hilog.info(0xFF10, 'VoiceCaptureService', 'builtin ASR onComplete: %{public}s', eventMessage);
    this.callbacks.onComplete(sessionId, eventMessage);
  }

  onError(sessionId: string, errorCode: number, errorMessage: string): void {
    hilog.error(0xFF10, 'VoiceCaptureService',
      'builtin ASR onError: %{public}d %{public}s', errorCode, errorMessage);
    this.callbacks.onError(errorCode, errorMessage);
  }

  onEvent(sessionId: string, eventCode: number, eventMessage: string): void {
    hilog.info(0xFF10, 'VoiceCaptureService',
      'builtin ASR onEvent: %{public}d %{public}s', eventCode, eventMessage);
    this.callbacks.onEvent(eventCode, eventMessage);
  }
}

class LocalAsrListenerAdapter implements AsrListener {
  private readonly onTranscript: (text: string) => void;

  constructor(onTranscript: (text: string) => void) {
    this.onTranscript = onTranscript;
  }

  onPartial(text: string): void {
    this.onTranscript(text);
  }

  onFinal(text: string): void {
    this.onTranscript(text);
  }

  onError(message: string): void {
    hilog.warn(0xFF10, 'VoiceCaptureService', 'local ASR callback error: %{public}s', message);
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
  private asrFinalizedText: string = '';
  private asrSampleRate: number = 16000;
  private asrLanguage: string = '';
  private runtimeContext?: common.Context;
  private localAsrProvider?: SenseVoiceLocalAsrProvider;
  private useLocalAsr: boolean = false;
  private useBuiltinAsr: boolean = false;
  private pendingBuiltinAudio: Uint8Array = new Uint8Array(0);
  private onTranscriptUpdate?: (text: string) => void;
  // True only between a successful startListening and the matching onComplete/onError.
  // Used as the mutex for restart attempts and as the gate that decides whether
  // incoming audio frames can be written to the engine immediately.
  private asrListening: boolean = false;
  private asrRestartScheduled: boolean = false;
  private capturedFrameCount: number = 0;
  private capturedSampleCount: number = 0;
  private captureStartedAtMs: number = 0;
  private effectiveCaptureSampleRate: number = 16000;
  private lastReadDataLogAtMs: number = 0;

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
      let frameStats = calculatePcm16FrameStats(uint8Buffer);
      this.state.chunks.push(uint8Buffer);
      this.capturedFrameCount += 1;
      this.capturedSampleCount += frameStats.sampleCount;
      this.logReadDataStatsIfNeeded(uint8Buffer.byteLength, frameStats);
      if (this.useLocalAsr && this.localAsrProvider) {
        this.localAsrProvider.pushAudioFrame(uint8Buffer);
      }
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
    this.asrFinalizedText = '';
    this.asrListening = false;
    this.asrRestartScheduled = false;
    this.capturedFrameCount = 0;
    this.capturedSampleCount = 0;
    this.captureStartedAtMs = 0;
    this.lastReadDataLogAtMs = 0;
    await this.shutdownLocalAsr();
    this.useBuiltinAsr = false;
    this.pendingBuiltinAudio = new Uint8Array(0);

    let providerId = resolveAsrProviderId(config.asrProvider);
    if (providerId === 'remote' && config.asrEndpoint.length === 0) {
      throw new Error('remote ASR selected but asrEndpoint is empty');
    }

    await this.tryStartLocalAsr(config, locale, providerId);
    let captureSampleRate = this.useLocalAsr ? resolveSenseVoiceCaptureSampleRate(config) : config.sampleRate;
    let sampleRate = resolveSampleRate(captureSampleRate);
    this.effectiveCaptureSampleRate = captureSampleRate;

    // 自动/内置模式下当前语言为中文时，尝试使用系统内置 ASR。
    // 真机上 CoreSpeechKit 可能因设备/签名/服务状态等原因初始化失败，
    // 此处必须降级为"只采集 PCM + 最终走远程/mock 转写"，而不是直接
    // 抛错阻塞整个录音启动——否则 UI 永远进入不到 'recording' 状态，
    // 用户看到的就是"按大圆圈没有脉冲"。
    if (!this.useLocalAsr && this.shouldTryBuiltinAsr(providerId) && this.isLocaleSupportedByBuiltinAsr(locale)) {
      try {
        await this.initBuiltinAsr(config, locale);
        this.useBuiltinAsr = true;
        hilog.info(0xFF10, 'VoiceCaptureService', 'builtin ASR initialized for %{public}s', locale);
      } catch (error) {
        let errorMsg = (error as Error).message ?? String(error);
        hilog.warn(0xFF10, 'VoiceCaptureService',
          'builtin ASR unavailable, falling back to audio-only capture: %{public}s', errorMsg);
        this.shutdownBuiltinAsr();
        this.useBuiltinAsr = false;
        if (providerId === 'builtin') {
          throw new Error(errorMsg);
        }
      }
    } else if (!this.useLocalAsr && providerId === 'builtin') {
      throw new Error(`builtin ASR does not support locale ${locale}`);
    } else if (!this.useLocalAsr && providerId === 'auto' && config.asrEndpoint.length === 0) {
      hilog.info(0xFF10, 'VoiceCaptureService',
        'locale %{public}s not supported by builtin ASR, will use mock/remote', locale);
    }

    hilog.info(0xFF10, 'VoiceCaptureService',
      'creating AudioCapturer with sampleRate=%{public}d local=%{public}s',
      captureSampleRate, String(this.useLocalAsr));
    try {
      this.capturer = await this.createCapturerWithFallback(sampleRate);
      this.updateLocalAsrSampleRateIfNeeded(this.logCapturerStreamInfo(this.capturer, 'created'));
    } catch (error) {
      let errorMsg = (error as Error).message ?? String(error);
      hilog.error(0xFF10, 'VoiceCaptureService', 'createAudioCapturer failed: %{public}s', errorMsg);
      this.shutdownBuiltinAsr();
      await this.shutdownLocalAsr();
      throw new Error(
        `音频录制初始化失败(${errorMsg})，鸿蒙模拟器不支持麦克风，请在真机上测试。`);
    }
    this.capturer.on('readData', this.onReadData);
    hilog.info(0xFF10, 'VoiceCaptureService', 'starting AudioCapturer...');
    this.state.active = true;
    this.state.startedAt = Date.now();
    this.captureStartedAtMs = this.state.startedAt;
    try {
      await this.capturer.start();
    } catch (error) {
      let errorMsg = (error as Error).message ?? String(error);
      hilog.error(0xFF10, 'VoiceCaptureService', 'capturer.start failed: %{public}s', errorMsg);
      this.capturer.off('readData', this.onReadData);
      await this.capturer.release();
      this.capturer = undefined;
      this.shutdownBuiltinAsr();
      await this.shutdownLocalAsr();
      this.state.active = false;
      throw new Error(errorMsg);
    }
    hilog.info(0xFF10, 'VoiceCaptureService', 'AudioCapturer started successfully');
    this.updateLocalAsrSampleRateIfNeeded(this.logCapturerStreamInfo(this.capturer, 'started'));
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

    if (this.useLocalAsr && this.localAsrProvider) {
      let provider = this.localAsrProvider;
      this.useLocalAsr = false;
      this.localAsrProvider = undefined;
      try {
        let result = await provider.stop(false);
        this.resetChunks();
        return result;
      } catch (error) {
        hilog.warn(0xFF10, 'VoiceCaptureService', 'local ASR stop failed: %{public}s',
          (error as Error).message ?? String(error));
        await provider.destroy();
      }
    }

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
    let providerId = resolveAsrProviderId(config.asrProvider);
    let pcmData = mergeChunks(this.state.chunks);
    this.resetChunks();
    if ((providerId === 'auto' || providerId === 'remote') && config.asrEndpoint.length > 0 &&
      pcmData.byteLength > 0) {
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
    if (providerId === 'remote') {
      return {
        text: '',
        source: 'remote_asr'
      };
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

  setRuntimeContext(context?: common.Context): void {
    this.runtimeContext = context;
    this.localAsrProvider?.setContext(context);
  }

  private resetChunks(): void {
    this.state.chunks = [];
  }

  private logReadDataStatsIfNeeded(chunkBytes: number, frameStats: Pcm16FrameStats): void {
    let now = Date.now();
    if (now - this.lastReadDataLogAtMs < 1000) {
      return;
    }
    this.lastReadDataLogAtMs = now;
    let elapsedMs = Math.max(1, now - this.captureStartedAtMs);
    let estimatedHz = Math.round(this.capturedSampleCount * 1000 / elapsedMs);
    hilog.info(0xFF10, 'VoiceCaptureService',
      'captured audio frame count=%{public}d lastBytes=%{public}d sampleRate=%{public}d estimatedHz=%{public}d rms=%{public}d peak=%{public}d local=%{public}s builtin=%{public}s',
      this.capturedFrameCount, chunkBytes, this.effectiveCaptureSampleRate, estimatedHz,
      Math.round(frameStats.rms), frameStats.peak, String(this.useLocalAsr), String(this.useBuiltinAsr));
  }

  private logCapturerStreamInfo(capturer: audio.AudioCapturer, stage: string): number | undefined {
    try {
      let streamInfo = capturer.getStreamInfoSync();
      let actualSampleRate = Number(streamInfo.samplingRate);
      hilog.info(0xFF10, 'VoiceCaptureService',
        'AudioCapturer %{public}s streamInfo sampleRate=%{public}d channels=%{public}d sampleFormat=%{public}d',
        stage, actualSampleRate, streamInfo.channels, streamInfo.sampleFormat);
      return actualSampleRate > 0 ? actualSampleRate : undefined;
    } catch (error) {
      hilog.warn(0xFF10, 'VoiceCaptureService',
        'AudioCapturer %{public}s getStreamInfo failed: %{public}s',
        stage, (error as Error).message ?? String(error));
      return undefined;
    }
  }

  private updateLocalAsrSampleRateIfNeeded(sampleRate?: number): void {
    if (!this.useLocalAsr || !sampleRate) {
      return;
    }
    if (sampleRate !== this.effectiveCaptureSampleRate) {
      hilog.warn(0xFF10, 'VoiceCaptureService',
        'local ASR capture sampleRate adjusted from %{public}d to %{public}d',
        this.effectiveCaptureSampleRate, sampleRate);
    }
    this.effectiveCaptureSampleRate = sampleRate;
    this.localAsrProvider?.setCaptureSampleRate(sampleRate);
  }

  private shouldTryBuiltinAsr(providerId: VoiceAsrProviderId): boolean {
    return providerId === 'auto' || providerId === 'builtin';
  }

  private async tryStartLocalAsr(config: OffhandVoiceConfig, locale: string,
    providerId: VoiceAsrProviderId): Promise<boolean> {
    if (providerId !== 'auto' && providerId !== 'sensevoice_local') {
      return false;
    }
    let provider = this.localAsrProvider ?? new SenseVoiceLocalAsrProvider(this.runtimeContext);
    provider.setContext(this.runtimeContext);
    this.localAsrProvider = provider;
    let available = await provider.isAvailable(config, locale);
    if (!available) {
      let reason = provider.getUnavailableReason();
      if (providerId === 'sensevoice_local') {
        throw new Error(`local ASR unavailable: ${reason}`);
      }
      hilog.info(0xFF10, 'VoiceCaptureService', 'local ASR skipped: %{public}s', reason);
      return false;
    }
    let listener: AsrListener = new LocalAsrListenerAdapter((text: string): void => {
      this.onTranscriptUpdate?.(text);
    });
    try {
      await provider.start(config, locale, listener);
      this.useLocalAsr = true;
      hilog.info(0xFF10, 'VoiceCaptureService', 'local SenseVoice ASR initialized for %{public}s', locale);
      return true;
    } catch (error) {
      await provider.destroy();
      this.useLocalAsr = false;
      if (providerId === 'sensevoice_local') {
        throw new Error((error as Error).message ?? String(error));
      }
      hilog.warn(0xFF10, 'VoiceCaptureService', 'local ASR start failed, falling back: %{public}s',
        (error as Error).message ?? String(error));
      return false;
    }
  }

  private async shutdownLocalAsr(): Promise<void> {
    if (!this.localAsrProvider) {
      this.useLocalAsr = false;
      return;
    }
    try {
      await this.localAsrProvider.destroy();
    } catch (_) {
    }
    this.localAsrProvider = undefined;
    this.useLocalAsr = false;
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
      this.asrFinalizedText = '';
      this.asrSampleRate = config.sampleRate;
      this.asrLanguage = locale;

      this.attachBuiltinAsrListener();
      this.startBuiltinAsrListening(this.asrSessionId);
    } catch (error) {
      throw new Error(`SpeechRecognizer unavailable: ${(error as Error).message ?? String(error)}`);
    }
  }

  private attachBuiltinAsrListener(): void {
    if (!this.asrEngine) {
      return;
    }
    let callbacks: BuiltinAsrListenerCallbacks = {
      onStart: (_sessionId: string): void => {
        // Engine is now ready to receive writeAudio for the current session.
        // Flush anything the AudioCapturer buffered while we were between
        // sessions so the first words after a pause are not dropped.
        this.asrListening = true;
        this.asrRestartScheduled = false;
        this.drainBufferedAudioToEngine();
      },
      onResult: (result: speechRecognizer.SpeechRecognitionResult): void => {
        this.handleBuiltinAsrResult(result);
      },
      onComplete: (_sessionId: string, _eventMessage: string): void => {
        this.asrListening = false;
        this.maybeRestartBuiltinAsrAfterComplete('onComplete');
      },
      onError: (errorCode: number, errorMessage: string): void => {
        this.asrListening = false;
        // 1002200010 = writeAudio 在未启动状态下被调用；engine 在长语音模式下仍可能主动停止，此处兜底重启
        if (this.state.active && this.useBuiltinAsr) {
          this.maybeRestartBuiltinAsrAfterComplete(`onError ${errorCode} ${errorMessage}`);
        }
      },
      onEvent: (eventCode: number, _eventMessage: string): void => {
        // eventCode 3 = 音频结束；若引擎自行结束而录音仍在继续，尝试重启
        if (eventCode === 3 && this.state.active && this.useBuiltinAsr) {
          this.asrListening = false;
          this.maybeRestartBuiltinAsrAfterComplete('audio-ended');
        }
      }
    };
    let listener: speechRecognizer.RecognitionListener = new BuiltinAsrListenerAdapter(callbacks);
    this.asrEngine.setListener(listener);
  }

  private startBuiltinAsrListening(sessionId: string): void {
    if (!this.asrEngine) {
      return;
    }
    let audioInfo: speechRecognizer.AudioInfo = {
      audioType: 'pcm',
      sampleRate: this.asrSampleRate,
      soundChannel: 1,
      sampleBit: 16
    };
    // 启用长语音模式，避免单句 VAD 结束后引擎停止接收音频
    let extraParams: Record<string, Object> = {
      'recognitionMode': BUILTIN_ASR_RECOGNITION_MODE_LONG,
      'vadEndWaitMs': BUILTIN_ASR_VAD_END_SILENCE_MS,
      'maxAudioDuration': BUILTIN_ASR_MAX_AUDIO_MS
    };
    let startParams: speechRecognizer.StartParams = {
      sessionId: sessionId,
      audioInfo: audioInfo,
      extraParams: extraParams
    };
    this.asrListening = false;
    this.asrEngine.startListening(startParams);
  }

  private handleBuiltinAsrResult(result: speechRecognizer.SpeechRecognitionResult): void {
    let text = result.result ?? '';
    if (result.isFinal) {
      // 一句话的最终结果：累加到已定稿文本
      if (text.length > 0) {
        this.asrFinalizedText = this.asrFinalizedText.length > 0
          ? `${this.asrFinalizedText}${text}`
          : text;
      }
      this.asrResultText = this.asrFinalizedText;
    } else {
      // 中间结果：作为预览附加在已定稿文本之后
      this.asrResultText = this.asrFinalizedText.length > 0
        ? `${this.asrFinalizedText}${text}`
        : text;
    }
    if (this.onTranscriptUpdate) {
      this.onTranscriptUpdate(this.asrResultText);
    }
  }

  private maybeRestartBuiltinAsrAfterComplete(reason: string): void {
    if (!this.state.active || !this.useBuiltinAsr || !this.asrEngine) {
      return;
    }
    // Coalesce the overlapping onComplete / onEvent(3) / onError bursts that
    // the recognizer fires for a single VAD boundary into one restart.
    if (this.asrRestartScheduled || this.asrListening) {
      return;
    }
    this.asrRestartScheduled = true;
    hilog.info(0xFF10, 'VoiceCaptureService',
      'restarting builtin ASR listening, reason=%{public}s', reason);
    // Keep whatever audio already accumulated in pendingBuiltinAudio; do NOT
    // drop it — those bytes are what the user said right before/around the
    // VAD boundary and would otherwise be lost. They will be written via
    // drainBufferedAudioToEngine once onStart confirms the new session is
    // ready.
    this.asrSessionId = `voice-${Date.now()}`;
    try {
      this.startBuiltinAsrListening(this.asrSessionId);
    } catch (error) {
      hilog.warn(0xFF10, 'VoiceCaptureService',
        'restart builtin ASR failed: %{public}s',
        (error as Error).message ?? String(error));
      this.asrRestartScheduled = false;
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
    this.asrListening = false;
    this.asrRestartScheduled = false;
    this.onTranscriptUpdate = undefined;
  }

  private enqueueBuiltinAsrAudio(chunk: Uint8Array): void {
    this.pendingBuiltinAudio = concatUint8Arrays(this.pendingBuiltinAudio, chunk);
    if (!this.asrListening) {
      // Engine is between sessions (VAD just ended, restart pending). Keep
      // accumulating so the first words after the pause survive.
      return;
    }
    this.drainBufferedAudioToEngine();
  }

  private drainBufferedAudioToEngine(): void {
    if (!this.asrEngine || !this.asrListening) {
      return;
    }
    while (this.pendingBuiltinAudio.byteLength >= BUILTIN_ASR_FRAME_BYTES) {
      let frame = this.pendingBuiltinAudio.slice(0, BUILTIN_ASR_FRAME_BYTES);
      try {
        this.asrEngine.writeAudio(this.asrSessionId, frame);
      } catch (error) {
        hilog.warn(0xFF10, 'VoiceCaptureService',
          'writeAudio failed, will buffer and retry after restart: %{public}s',
          (error as Error).message ?? String(error));
        this.asrListening = false;
        this.maybeRestartBuiltinAsrAfterComplete('writeAudio-failed');
        return;
      }
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

function calculatePcm16FrameStats(frame: Uint8Array): Pcm16FrameStats {
  let sampleCount = Math.floor(frame.byteLength / 2);
  if (sampleCount === 0) {
    return {
      sampleCount: 0,
      rms: 0,
      peak: 0
    };
  }
  let view = new DataView(frame.buffer, frame.byteOffset, sampleCount * 2);
  let sumSquares = 0;
  let peak = 0;
  for (let index = 0; index < sampleCount; index++) {
    let sample = view.getInt16(index * 2, true);
    let absValue = Math.abs(sample);
    if (absValue > peak) {
      peak = absValue;
    }
    sumSquares += sample * sample;
  }
  return {
    sampleCount: sampleCount,
    rms: Math.sqrt(sumSquares / sampleCount),
    peak: peak
  };
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

function resolveAsrProviderId(raw: string | undefined): VoiceAsrProviderId {
  if (raw === 'sensevoice_local' || raw === 'builtin' || raw === 'remote') {
    return raw;
  }
  if (raw === 'zipformer_bilingual_local') {
    return 'sensevoice_local';
  }
  return 'auto';
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
