import { OffhandVoiceConfig, VoiceRecognitionResult } from '../common/ImeTypes';

export interface AsrListener {
  onPartial(text: string): void;
  onFinal(text: string): void;
  onError(message: string): void;
}

export interface AsrProvider {
  readonly id: string;
  isAvailable(config: OffhandVoiceConfig, locale: string): Promise<boolean>;
  start(config: OffhandVoiceConfig, locale: string, listener: AsrListener): Promise<void>;
  pushAudioFrame(frame: Uint8Array): void;
  stop(discardResult: boolean): Promise<VoiceRecognitionResult>;
  destroy(): Promise<void>;
}
