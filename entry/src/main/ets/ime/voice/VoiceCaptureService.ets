import audio from '@ohos.multimedia.audio';
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

export class VoiceCaptureService {
  private capturer?: audio.AudioCapturer;
  private readonly httpClient: RemoteHttpClient = new RemoteHttpClient();
  private readonly base64Helper: util.Base64Helper = new util.Base64Helper();
  private readonly state: VoiceSessionState = {
    active: false,
    startedAt: 0,
    chunks: []
  };
  private readonly onReadData = (buffer: ArrayBuffer): void => {
    if (!this.state.active) {
      return;
    }
    this.state.chunks.push(new Uint8Array(buffer));
  };

  async start(config: OffhandVoiceConfig): Promise<void> {
    if (this.state.active) {
      hilog.warn(0xFF10, 'VoiceCaptureService', 'start called but already active');
      return;
    }
    this.resetChunks();
    let sampleRate = resolveSampleRate(config.sampleRate);
    hilog.info(0xFF10, 'VoiceCaptureService', 'creating AudioCapturer with sampleRate=%{public}d', config.sampleRate);
    try {
      this.capturer = await this.createCapturerWithFallback(sampleRate);
    } catch (error) {
      let errorMsg = (error as Error).message ?? String(error);
      hilog.error(0xFF10, 'VoiceCaptureService', 'createAudioCapturer failed: %{public}s', errorMsg);
      throw new Error(errorMsg);
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
      throw new Error(errorMsg);
    }
    this.state.active = true;
    this.state.startedAt = Date.now();
    hilog.info(0xFF10, 'VoiceCaptureService', 'AudioCapturer started successfully');
  }

  async stop(config: OffhandVoiceConfig, locale: string): Promise<VoiceRecognitionResult> {
    if (!this.state.active || !this.capturer) {
      return {
        text: config.mockTranscript,
        source: 'mock'
      };
    }
    let capturer = this.capturer;
    this.state.active = false;
    try {
      await capturer.stop();
    } finally {
      capturer.off('readData', this.onReadData);
      await capturer.release();
      this.capturer = undefined;
    }
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

  private resetChunks(): void {
    this.state.chunks = [];
  }

  private async createCapturerWithFallback(sampleRate: audio.AudioSamplingRate): Promise<audio.AudioCapturer> {
    try {
      return await this.createCapturer(sampleRate, audio.SourceType.SOURCE_TYPE_VOICE_RECOGNITION);
    } catch (_) {
      return await this.createCapturer(sampleRate, audio.SourceType.SOURCE_TYPE_MIC);
    }
  }

  private async createCapturer(sampleRate: audio.AudioSamplingRate, source: audio.SourceType): Promise<audio.AudioCapturer> {
    return await audio.createAudioCapturer({
      streamInfo: {
        samplingRate: sampleRate,
        channels: audio.AudioChannel.CHANNEL_1,
        sampleFormat: audio.AudioSampleFormat.SAMPLE_FORMAT_S16LE,
        encodingType: audio.AudioEncodingType.ENCODING_TYPE_RAW
      },
      capturerInfo: {
        source: source,
        capturerFlags: 0
      }
    });
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
