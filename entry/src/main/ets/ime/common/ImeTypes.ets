export interface RimeOptionState {
  ascii_mode: boolean;
  full_shape: boolean;
}

export type KeyboardLayoutId = 'qwerty_26' | 't9_9' | 'voice_panel';

export interface KeyboardLayoutOption {
  id: KeyboardLayoutId;
  label: string;
}

export interface OffhandSubtypeExtras {
  punctuationMode?: string;
  autoCapitalize?: boolean;
  partialResult?: boolean;
  supportedKeyboardLayouts?: KeyboardLayoutId[];
}

export type VoiceInputState = 'idle' | 'recording' | 'processing' | 'error';

export interface CandidateItem {
  index: number;
  text: string;
  comment: string;
  label: string;
  highlighted: boolean;
}

export interface RimeState {
  schemaId: string;
  rawInput: string;
  composingText: string;
  commitText: string;
  candidates: CandidateItem[];
  isAsciiMode: boolean;
  options: RimeOptionState;
  pageSize: number;
  pageNo: number;
  isLastPage: boolean;
  highlightedCandidateIndex: number;
  selectKeys: string;
}

export interface SubtypeSummary {
  id: string;
  name: string;
}

export interface OffhandSubtypeConfig {
  id: string;
  name: string;
  locale: string;
  language: string;
  mode: 'upper' | 'lower';
  engine: string;
  schemaId?: string;
  keyboardLayout: KeyboardLayoutId;
  voiceEnabled: boolean;
  llmPolishEnabled: boolean;
  domainHints: string[];
  extra?: OffhandSubtypeExtras;
}

export interface OffhandAppConfig {
  bundleName: string;
  defaultSubtypeId: string;
  enableCloudFeaturesByDefault: boolean;
  maxConcurrentSessions: number;
}

export interface OffhandInputConfig {
  candidatePageSize: number;
  maxCompositionLength: number;
  commitOnSpace: boolean;
  enablePreviewText: boolean;
}

export interface OffhandRimeConfig {
  schemaId: string;
  sharedDataDir: string;
  userDataDir: string;
  preloadSchemas: string[];
  options: RimeOptionState;
}

export interface OffhandPinyinConfig {
  engine: string;
  rime: OffhandRimeConfig;
}

export interface OffhandVoiceConfig {
  enabled: boolean;
  sampleRate: number;
  maxRecordSeconds: number;
  requestTimeoutMs: number;
  asrEndpoint: string;
  apiKey?: string;
  autoInsertResult: boolean;
  autoPolishResult: boolean;
  mockTranscript: string;
}

export interface OffhandLlmPolishConfig {
  enabled: boolean;
  endpoint: string;
  apiKey?: string;
  requestTimeoutMs: number;
  autoPolishVoiceResult: boolean;
  fallbackToLocalRewrite: boolean;
  style: string;
}

export interface OffhandPrivacyConfig {
  enablePersonalization: boolean;
}

export interface OffhandImeConfig {
  version: number;
  app: OffhandAppConfig;
  input: OffhandInputConfig;
  pinyin: OffhandPinyinConfig;
  voice: OffhandVoiceConfig;
  llmPolish: OffhandLlmPolishConfig;
  privacy: OffhandPrivacyConfig;
}

export interface OffhandRuntimeSettings {
  enablePreviewText: boolean;
  enableVoice: boolean;
  enableCloudPolish: boolean;
  enablePersonalization: boolean;
  autoInsertVoiceResult: boolean;
  autoPolishVoiceResult: boolean;
  asrEndpoint: string;
  llmEndpoint: string;
  llmStyle: string;
}

export interface RimeInitOptions {
  sharedDataDir: string;
  userDataDir: string;
  schemaId: string;
  options: RimeOptionState;
}

export interface SessionCapabilitySnapshot {
  voiceEnabled: boolean;
  polishEnabled: boolean;
  personalizedLearning: boolean;
  restrictedReason: string;
  isSensitiveField: boolean;
}

export interface InputSessionContext {
  inputPattern: number;
  enterKeyType: number;
  placeholder: string;
  abilityName: string;
  bundleName: string;
  securityMode: number;
  subtypeId: string;
  schemaId: string;
  keyboardLayout: KeyboardLayoutId;
  supportsPreviewText: boolean;
}

export interface VoiceRecognitionResult {
  text: string;
  source: 'remote_asr' | 'mock';
}

export interface PolishSuggestion {
  sourceText: string;
  suggestedText: string;
  source: 'manual' | 'voice_auto';
  provider: string;
}
