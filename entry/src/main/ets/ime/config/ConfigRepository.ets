import { common } from '@kit.AbilityKit';
import fileIo from '@ohos.file.fs';
import { util } from '@kit.ArkTS';
import { InputMethodExtensionContext } from '@kit.IMEKit';
import {
  KeyboardLayoutId,
  OffhandAppConfig,
  OffhandImeConfig,
  OffhandInputConfig,
  OffhandLlmPolishConfig,
  OffhandPinyinConfig,
  OffhandPrivacyConfig,
  OffhandRuntimeSettings,
  OffhandRimeConfig,
  OffhandSubtypeExtras,
  OffhandSubtypeConfig,
  OffhandVoiceConfig,
  RimeInitOptions,
  RimeOptionState,
  SubtypeSummary
} from '../common/ImeTypes';
import { cloneRuntimeSettings, createDefaultRuntimeSettings, OffhandSettingsStore } from '../../settings/OffhandSettingsStore';

interface SubtypeEnvelope {
  subtypes: OffhandSubtypeConfig[];
}

const RIME_SHARED_RAWFILE_ROOT = 'rime/shared';
const RIME_SHARED_FILES: string[] = [
  'default.yaml',
  'offhand_pinyin.schema.yaml',
  'offhand_pinyin.custom.yaml',
  'luna_pinyin.dict.yaml',
  'essay.txt'
];

export class ConfigRepository {
  private readonly decoder: util.TextDecoder = util.TextDecoder.create('utf-8');
  private readonly settingsStore: OffhandSettingsStore = new OffhandSettingsStore();
  private baseConfig: OffhandImeConfig = createDefaultConfig();
  private config: OffhandImeConfig = createDefaultConfig();
  private runtimeSettings: OffhandRuntimeSettings = createDefaultRuntimeSettings();
  private subtypes: OffhandSubtypeConfig[] = createDefaultSubtypes();
  private initialized: boolean = false;
  private preparedSharedDataDir: string = '';

  async initialize(context: InputMethodExtensionContext): Promise<void> {
    this.baseConfig = await this.loadJsonResource<OffhandImeConfig>(context, 'offhand-ime-config.json', createDefaultConfig());
    this.config = cloneConfig(this.baseConfig);
    let subtypePayload = await this.loadJsonResource<SubtypeEnvelope | OffhandSubtypeConfig[]>(
      context,
      'inputmethod-subtypes.json',
      createDefaultSubtypes()
    );
    if (Array.isArray(subtypePayload)) {
      this.subtypes = subtypePayload;
    } else {
      let envelope = subtypePayload as SubtypeEnvelope;
      if (Array.isArray(envelope.subtypes) && envelope.subtypes.length > 0) {
        this.subtypes = envelope.subtypes;
      }
    }
    if (this.subtypes.length === 0) {
      this.subtypes = createDefaultSubtypes();
    }
    this.subtypes = this.subtypes.map((subtype: OffhandSubtypeConfig): OffhandSubtypeConfig => normalizeSubtype(subtype));
    await this.refreshRuntimeSettings(context);
    this.initialized = true;
  }

  isInitialized(): boolean {
    return this.initialized;
  }

  getConfig(): OffhandImeConfig {
    return this.config;
  }

  getRuntimeSettings(): OffhandRuntimeSettings {
    return cloneRuntimeSettings(this.runtimeSettings);
  }

  listSubtypeConfigs(): OffhandSubtypeConfig[] {
    let copies: OffhandSubtypeConfig[] = [];
    for (let index = 0; index < this.subtypes.length; index++) {
      copies.push(cloneSubtype(this.subtypes[index]));
    }
    return copies;
  }

  listSubtypeSummaries(): SubtypeSummary[] {
    return this.subtypes.map((subtype: OffhandSubtypeConfig): SubtypeSummary => ({
      id: subtype.id,
      name: subtype.name
    }));
  }

  getDefaultSubtype(): OffhandSubtypeConfig {
    return this.resolveSubtypeById(this.config.app.defaultSubtypeId);
  }

  resolveSubtypeById(subtypeId: string): OffhandSubtypeConfig {
    for (let index = 0; index < this.subtypes.length; index++) {
      let subtype = this.subtypes[index];
      if (subtype.id === subtypeId) {
        return subtype;
      }
    }
    return this.subtypes.length > 0 ? this.subtypes[0] : createDefaultSubtypes()[0];
  }

  async buildRimeInitOptions(context: InputMethodExtensionContext): Promise<RimeInitOptions> {
    let rime = this.config.pinyin.rime;
    let sharedDataDir = resolveAppPrivatePath(rime.sharedDataDir, context.filesDir, 'rime/shared');
    let userDataDir = resolveAppPrivatePath(rime.userDataDir, context.filesDir, 'rime/user');
    await this.prepareRimeSharedData(context, sharedDataDir);
    ensureDirectory(userDataDir);
    let options: RimeOptionState = cloneOptionState(rime.options);
    let initOptions: RimeInitOptions = {
      sharedDataDir: sharedDataDir,
      userDataDir: userDataDir,
      schemaId: rime.schemaId,
      options: options
    };
    return initOptions;
  }

  async refreshRuntimeSettings(context: common.Context): Promise<void> {
    this.runtimeSettings = await this.settingsStore.load(context);
    this.config = applyRuntimeSettings(this.baseConfig, this.runtimeSettings);
  }

  private async loadJsonResource<T>(context: InputMethodExtensionContext, path: string, fallback: T): Promise<T> {
    try {
      let content = await context.resourceManager.getRawFileContent(path);
      let text = this.decoder.decodeToString(content);
      return JSON.parse(text) as T;
    } catch (_) {
      return fallback;
    }
  }

  private async prepareRimeSharedData(context: InputMethodExtensionContext, targetDir: string): Promise<void> {
    if (this.preparedSharedDataDir === targetDir) {
      return;
    }
    ensureDirectory(targetDir);
    for (let index = 0; index < RIME_SHARED_FILES.length; index++) {
      let fileName = RIME_SHARED_FILES[index];
      let rawPath = `${RIME_SHARED_RAWFILE_ROOT}/${fileName}`;
      let targetPath = `${targetDir}/${fileName}`;
      let content = await context.resourceManager.getRawFileContent(rawPath);
      writeBinaryFile(targetPath, content);
    }
    this.preparedSharedDataDir = targetDir;
  }
}

function createDefaultConfig(): OffhandImeConfig {
  let appConfig: OffhandAppConfig = {
    bundleName: 'com.opensource.harmony.offhand',
    defaultSubtypeId: 'zh-Hans-pinyin',
    enableCloudFeaturesByDefault: false,
    maxConcurrentSessions: 1
  };
  let inputConfig: OffhandInputConfig = {
    candidatePageSize: 8,
    maxCompositionLength: 64,
    commitOnSpace: true,
    enablePreviewText: true
  };
  let rimeOptions: RimeOptionState = {
    ascii_mode: false,
    full_shape: false
  };
  let rimeConfig: OffhandRimeConfig = {
    schemaId: 'offhand_pinyin',
    sharedDataDir: '<app_private>/rime/shared',
    userDataDir: '<app_private>/rime/user',
    preloadSchemas: ['offhand_pinyin'],
    options: rimeOptions
  };
  let pinyinConfig: OffhandPinyinConfig = {
    engine: 'librime',
    rime: rimeConfig
  };
  let voiceConfig: OffhandVoiceConfig = {
    enabled: true,
    sampleRate: 16000,
    maxRecordSeconds: 45,
    requestTimeoutMs: 20000,
    asrEndpoint: '',
    autoInsertResult: false,
    autoPolishResult: true,
    mockTranscript: '这是一次语音输入示例'
  };
  let llmConfig: OffhandLlmPolishConfig = {
    enabled: true,
    endpoint: '',
    requestTimeoutMs: 12000,
    autoPolishVoiceResult: true,
    fallbackToLocalRewrite: true,
    style: 'clean_conversational'
  };
  let privacyConfig: OffhandPrivacyConfig = {
    enablePersonalization: true
  };
  let config: OffhandImeConfig = {
    version: 1,
    app: appConfig,
    input: inputConfig,
    pinyin: pinyinConfig,
    voice: voiceConfig,
    llmPolish: llmConfig,
    privacy: privacyConfig
  };
  return config;
}

function applyRuntimeSettings(base: OffhandImeConfig, runtime: OffhandRuntimeSettings): OffhandImeConfig {
  let merged = cloneConfig(base);
  merged.input.enablePreviewText = runtime.enablePreviewText;
  merged.voice.enabled = runtime.enableVoice;
  merged.voice.autoInsertResult = runtime.autoInsertVoiceResult;
  merged.voice.autoPolishResult = runtime.autoPolishVoiceResult;
  merged.voice.asrEndpoint = runtime.asrEndpoint;
  merged.llmPolish.enabled = runtime.enableCloudPolish;
  merged.llmPolish.autoPolishVoiceResult = runtime.autoPolishVoiceResult;
  merged.llmPolish.endpoint = runtime.llmEndpoint;
  merged.llmPolish.style = runtime.llmStyle;
  merged.privacy.enablePersonalization = runtime.enablePersonalization;
  return merged;
}

function createDefaultSubtypes(): OffhandSubtypeConfig[] {
  let zhExtra: OffhandSubtypeExtras = {
    punctuationMode: 'zh',
    supportedKeyboardLayouts: ['qwerty_26', 't9_9']
  };
  let zhSubtype: OffhandSubtypeConfig = {
    id: 'zh-Hans-pinyin',
    name: '中文拼音',
    locale: 'zh-CN',
    language: 'zh',
    mode: 'lower',
    engine: 'librime',
    schemaId: 'offhand_pinyin',
    keyboardLayout: 'qwerty_26',
    voiceEnabled: true,
    llmPolishEnabled: true,
    domainHints: ['general', 'chat', 'office'],
    extra: zhExtra
  };

  let enExtra: OffhandSubtypeExtras = {
    autoCapitalize: true,
    supportedKeyboardLayouts: ['qwerty_26']
  };
  let enSubtype: OffhandSubtypeConfig = {
    id: 'en-US-qwerty',
    name: 'English',
    locale: 'en-US',
    language: 'en',
    mode: 'lower',
    engine: 'local_english',
    keyboardLayout: 'qwerty_26',
    voiceEnabled: false,
    llmPolishEnabled: false,
    domainHints: ['general', 'email', 'code'],
    extra: enExtra
  };

  let voiceExtra: OffhandSubtypeExtras = {
    partialResult: true,
    supportedKeyboardLayouts: ['voice_panel']
  };
  let voiceSubtype: OffhandSubtypeConfig = {
    id: 'zh-CN-voice',
    name: '语音输入',
    locale: 'zh-CN',
    language: 'zh',
    mode: 'lower',
    engine: 'librime',
    schemaId: 'offhand_pinyin',
    keyboardLayout: 'voice_panel',
    voiceEnabled: true,
    llmPolishEnabled: true,
    domainHints: ['chat', 'meeting'],
    extra: voiceExtra
  };

  let subtypes: OffhandSubtypeConfig[] = [zhSubtype, enSubtype, voiceSubtype];
  return subtypes;
}

function cloneOptionState(source: RimeOptionState): RimeOptionState {
  let options: RimeOptionState = {
    ascii_mode: source.ascii_mode,
    full_shape: source.full_shape
  };
  return options;
}

function cloneConfig(source: OffhandImeConfig): OffhandImeConfig {
  return {
    version: source.version,
    app: {
      bundleName: source.app.bundleName,
      defaultSubtypeId: source.app.defaultSubtypeId,
      enableCloudFeaturesByDefault: source.app.enableCloudFeaturesByDefault,
      maxConcurrentSessions: source.app.maxConcurrentSessions
    },
    input: {
      candidatePageSize: source.input.candidatePageSize,
      maxCompositionLength: source.input.maxCompositionLength,
      commitOnSpace: source.input.commitOnSpace,
      enablePreviewText: source.input.enablePreviewText
    },
    pinyin: {
      engine: source.pinyin.engine,
      rime: {
        schemaId: source.pinyin.rime.schemaId,
        sharedDataDir: source.pinyin.rime.sharedDataDir,
        userDataDir: source.pinyin.rime.userDataDir,
        preloadSchemas: source.pinyin.rime.preloadSchemas.slice(),
        options: cloneOptionState(source.pinyin.rime.options)
      }
    },
    voice: {
      enabled: source.voice.enabled,
      sampleRate: source.voice.sampleRate,
      maxRecordSeconds: source.voice.maxRecordSeconds,
      requestTimeoutMs: source.voice.requestTimeoutMs,
      asrEndpoint: source.voice.asrEndpoint,
      apiKey: source.voice.apiKey,
      autoInsertResult: source.voice.autoInsertResult,
      autoPolishResult: source.voice.autoPolishResult,
      mockTranscript: source.voice.mockTranscript
    },
    llmPolish: {
      enabled: source.llmPolish.enabled,
      endpoint: source.llmPolish.endpoint,
      apiKey: source.llmPolish.apiKey,
      requestTimeoutMs: source.llmPolish.requestTimeoutMs,
      autoPolishVoiceResult: source.llmPolish.autoPolishVoiceResult,
      fallbackToLocalRewrite: source.llmPolish.fallbackToLocalRewrite,
      style: source.llmPolish.style
    },
    privacy: {
      enablePersonalization: source.privacy.enablePersonalization
    }
  };
}

function cloneSubtype(source: OffhandSubtypeConfig): OffhandSubtypeConfig {
  let extra: OffhandSubtypeExtras | undefined = undefined;
  if (source.extra) {
    extra = {
      punctuationMode: source.extra.punctuationMode,
      autoCapitalize: source.extra.autoCapitalize,
      partialResult: source.extra.partialResult,
      supportedKeyboardLayouts: source.extra.supportedKeyboardLayouts ?
        source.extra.supportedKeyboardLayouts.slice() : undefined
    };
  }
  let cloned: OffhandSubtypeConfig = {
    id: source.id,
    name: source.name,
    locale: source.locale,
    language: source.language,
    mode: source.mode,
    engine: source.engine,
    schemaId: source.schemaId,
    keyboardLayout: source.keyboardLayout,
    voiceEnabled: source.voiceEnabled,
    llmPolishEnabled: source.llmPolishEnabled,
    domainHints: source.domainHints.slice(),
    extra: extra
  };
  return cloned;
}

function normalizeSubtype(source: OffhandSubtypeConfig): OffhandSubtypeConfig {
  let cloned = cloneSubtype(source);
  cloned.keyboardLayout = normalizeKeyboardLayout(cloned.keyboardLayout);
  if (!cloned.extra) {
    cloned.extra = {};
  }
  let supportedLayouts = cloned.extra.supportedKeyboardLayouts;
  if (!supportedLayouts || supportedLayouts.length === 0) {
    if (cloned.keyboardLayout === 'voice_panel') {
      supportedLayouts = ['voice_panel'];
    } else if (cloned.engine === 'local_english') {
      supportedLayouts = ['qwerty_26'];
    } else if (cloned.engine === 'librime') {
      supportedLayouts = ['qwerty_26', 't9_9'];
    } else {
      supportedLayouts = [cloned.keyboardLayout];
    }
  }
  let normalizedLayouts: KeyboardLayoutId[] = [];
  for (let index = 0; index < supportedLayouts.length; index++) {
    let layout = normalizeKeyboardLayout(supportedLayouts[index]);
    if (normalizedLayouts.indexOf(layout) >= 0) {
      continue;
    }
    normalizedLayouts.push(layout);
  }
  if (normalizedLayouts.length === 0) {
    normalizedLayouts.push(cloned.keyboardLayout);
  }
  if (normalizedLayouts.indexOf(cloned.keyboardLayout) < 0) {
    normalizedLayouts.unshift(cloned.keyboardLayout);
  }
  cloned.extra.supportedKeyboardLayouts = normalizedLayouts;
  return cloned;
}

function normalizeKeyboardLayout(layout?: string): KeyboardLayoutId {
  if (layout === 't9_9' || layout === 'voice_panel') {
    return layout;
  }
  return 'qwerty_26';
}

function ensureDirectory(path: string): void {
  try {
    if (fileIo.accessSync(path)) {
      return;
    }
  } catch (_) {
  }
  try {
    fileIo.mkdirSync(path, true);
    return;
  } catch (_) {
  }
}

function resolveAppPrivatePath(path: string, filesDir: string, fallbackSuffix: string): string {
  if (path.startsWith('<app_private>')) {
    return path.replace('<app_private>', filesDir);
  }
  if (path.startsWith('rawfile://')) {
    return `${filesDir}/${fallbackSuffix}`;
  }
  return path;
}

function writeBinaryFile(path: string, content: Uint8Array): void {
  let file = fileIo.openSync(path, fileIo.OpenMode.CREATE | fileIo.OpenMode.WRITE_ONLY | fileIo.OpenMode.TRUNC);
  try {
    let buffer = content.buffer.slice(content.byteOffset, content.byteOffset + content.byteLength);
    fileIo.writeSync(file.fd, buffer);
  } finally {
    fileIo.closeSync(file);
  }
}
