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
import { getDefaultBuiltinModelSelection, resolveBuiltinModelSelection } from './BuiltinModels';
import { cloneRuntimeSettings, createDefaultRuntimeSettings, OffhandSettingsStore } from '../../settings/OffhandSettingsStore';

interface SubtypeEnvelope {
  subtypes: OffhandSubtypeConfig[];
}

const RIME_SHARED_RAWFILE_ROOT = 'rime/shared';
// Bumped after 2026-04-22 fix that: (1) pre-simplifies essay.txt so candidates
// no longer rely on opencc/simplifier (opencc data files are not shipped);
// (2) drops the broken `simplifier` filter from the schema; (3) expands
// offhand.base.dict.yaml with high-weight common phrases (季节/集结/...).
const RIME_RESOURCE_VERSION = '20260422-simp-vocab-v5';
const RIME_PREPARED_SIGNATURE_FILE = '.offhand_rime_signature';
const RIME_SHARED_FILES: string[] = [
  'default.yaml',
  'pinyin.yaml',
  'offhand_pinyin.dict.yaml',
  'offhand_pinyin.schema.yaml',
  'offhand_pinyin.custom.yaml',
  'offhand.base.dict.yaml',
  'luna_pinyin.dict.yaml',
  'essay.txt'
];

const DEFAULT_SPELLER_ALGEBRA: string[] = [
  'erase/^xx$/',
  'abbrev/^([a-z]).+$/$1/',
  'abbrev/^([zcs]h).+$/$1/',
  'derive/^([nl])ve$/$1ue/',
  'derive/^([jqxy])u/$1v/',
  'derive/un$/uen/',
  'derive/ui$/uei/',
  'derive/iu$/iou/',
  'derive/([aeiou])ng$/$1gn/',
  'derive/ong$/on/',
  'derive/ao$/oa/'
];

export class ConfigRepository {
  private readonly decoder: util.TextDecoder = util.TextDecoder.create('utf-8');
  private readonly settingsStore: OffhandSettingsStore = new OffhandSettingsStore();
  private baseConfig: OffhandImeConfig = createDefaultConfig();
  private config: OffhandImeConfig = createDefaultConfig();
  private runtimeSettings: OffhandRuntimeSettings = createDefaultRuntimeSettings();
  private subtypes: OffhandSubtypeConfig[] = createDefaultSubtypes();
  private initialized: boolean = false;
  private lastPreparedSignature: string = '';

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

  // Returns the subtype that should be activated when the IME first attaches
  // to an editor, honoring the user-selected defaultEntryMode:
  //   - 'keyboard' (default): use the configured default subtype (26-key pinyin).
  //   - 'voice': use the voice subtype when voice input is enabled; otherwise fall back.
  getPreferredInitialSubtype(): OffhandSubtypeConfig {
    if (this.runtimeSettings.defaultEntryMode === 'voice' && this.runtimeSettings.enableVoice) {
      for (let index = 0; index < this.subtypes.length; index++) {
        let subtype = this.subtypes[index];
        if (subtype.keyboardLayout === 'voice_panel') {
          return subtype;
        }
      }
    }
    return this.getDefaultSubtype();
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
    ensureDirectory(userDataDir);
    let signature = `${sharedDataDir}|${userDataDir}|${buildRimeResourceSignature(this.config)}`;
    let preparedSignaturePath = `${userDataDir}/${RIME_PREPARED_SIGNATURE_FILE}`;
    let preparedSignature = this.lastPreparedSignature.length > 0 ?
      this.lastPreparedSignature :
      readTextFileIfExists(preparedSignaturePath).trim();
    // Only copy the shared data and wipe prebuilt/staging when the resource
    // signature actually changed. Re-running these steps on every re-focus
    // erased the `.table.bin`/`.prism.bin` produced by a previous deploy —
    // Rime's in-memory dictionary would keep working for the warm session,
    // but the next cold start would be left with an empty `build/` directory
    // and a flag cache indicating "already deployed", so phrase candidates
    // (e.g. 季节/集结 for `jijie`) silently disappeared.
    if (preparedSignature !== signature || !hasRequiredRimeSharedFiles(sharedDataDir)) {
      await this.prepareRimeSharedData(context, sharedDataDir);
      resetDirectoryContents(`${sharedDataDir}/build`);
      resetDirectoryContents(`${userDataDir}/build`);
      removeRecursively(`${userDataDir}/installation.yaml`);
      writeTextFile(preparedSignaturePath, signature);
    }
    this.lastPreparedSignature = signature;
    let options: RimeOptionState = cloneOptionState(rime.options);
    let initOptions: RimeInitOptions = {
      sharedDataDir: sharedDataDir,
      userDataDir: userDataDir,
      schemaId: rime.schemaId,
      options: options,
      resourceVersion: buildRimeResourceSignature(this.config)
    };
    return initOptions;
  }

  async refreshRuntimeSettings(context: common.Context): Promise<void> {
    this.runtimeSettings = await this.settingsStore.load(context);
    this.config = applyRuntimeSettings(this.baseConfig, this.runtimeSettings);
  }

  // Save the provided runtime settings through OffhandSettingsStore and
  // immediately reapply them to the in-memory config snapshot. Used by the
  // in-keyboard LLM settings panel so settings edited inside the IME
  // extension sandbox persist and take effect without a second load pass.
  async saveRuntimeSettings(context: common.Context, settings: OffhandRuntimeSettings): Promise<void> {
    await this.settingsStore.save(context, settings);
    this.runtimeSettings = settings;
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
    ensureDirectory(targetDir);
    for (let index = 0; index < RIME_SHARED_FILES.length; index++) {
      let fileName = RIME_SHARED_FILES[index];
      let targetPath = `${targetDir}/${fileName}`;
      let rawPath = `${RIME_SHARED_RAWFILE_ROOT}/${fileName}`;
      let content = await context.resourceManager.getRawFileContent(rawPath);
      writeUtf8ResourceFile(targetPath, this.decoder.decodeToString(content));
    }
    writeTextFile(`${targetDir}/offhand_pinyin.custom.yaml`, buildRimeCustomPatch(this.config));
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
    enablePreviewText: false
  };
  let rimeOptions: RimeOptionState = {
    ascii_mode: false,
    full_shape: false,
    emoji_suggestion: true
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
    enablePrediction: true,
    enableMixedInput: true,
    enableFuzzy: true,
    fuzzyPairs: [
      ['z', 'zh'],
      ['c', 'ch'],
      ['s', 'sh'],
      ['an', 'ang'],
      ['en', 'eng'],
      ['in', 'ing'],
      ['l', 'n']
    ],
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
  let llmConfig: OffhandLlmPolishConfig = createDefaultLlmPolishConfig();
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
  let selection = resolveBuiltinModelSelection(runtime.llmProviderId, runtime.llmPresetId);
  merged.input.enablePreviewText = runtime.enablePreviewText;
  merged.voice.enabled = runtime.enableVoice;
  merged.voice.autoInsertResult = runtime.autoInsertVoiceResult;
  merged.voice.autoPolishResult = runtime.autoPolishVoiceResult;
  merged.voice.asrEndpoint = runtime.asrEndpoint;
  merged.llmPolish.enabled = runtime.enableCloudPolish;
  merged.llmPolish.providerId = selection.provider.providerId;
  merged.llmPolish.providerName = selection.provider.providerName;
  merged.llmPolish.modelPresetId = selection.preset.presetId;
  merged.llmPolish.modelDisplayName = selection.preset.displayName;
  merged.llmPolish.apiModel = selection.preset.apiModel;
  merged.llmPolish.protocol = selection.preset.protocol;
  merged.llmPolish.endpoint = selection.preset.endpoint;
  merged.llmPolish.apiKey = runtime.llmApiKey.trim();
  merged.llmPolish.autoPolishVoiceResult = runtime.autoPolishVoiceResult;
  merged.llmPolish.style = runtime.llmStyle;
  merged.privacy.enablePersonalization = runtime.enablePersonalization;
  return merged;
}

function createDefaultLlmPolishConfig(): OffhandLlmPolishConfig {
  let selection = getDefaultBuiltinModelSelection();
  return {
    enabled: true,
    providerId: selection.provider.providerId,
    providerName: selection.provider.providerName,
    modelPresetId: selection.preset.presetId,
    modelDisplayName: selection.preset.displayName,
    apiModel: selection.preset.apiModel,
    protocol: selection.preset.protocol,
    endpoint: selection.preset.endpoint,
    // 12s was too aggressive for SSE first-token latency against remote
    // LLM gateways (observed 12s stream-timeout on GLM). Give the read
    // timeout enough slack for first-token plus the slowest finish.
    requestTimeoutMs: 45000,
    autoPolishVoiceResult: true,
    fallbackToLocalRewrite: true,
    style: 'clean_conversational'
  };
}

function createDefaultSubtypes(): OffhandSubtypeConfig[] {
  let zhExtra: OffhandSubtypeExtras = {
    punctuationMode: 'zh',
    supportedKeyboardLayouts: ['qwerty_26']
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
  if (source.emoji_suggestion !== undefined) {
    options.emoji_suggestion = source.emoji_suggestion;
  }
  return options;
}

function cloneConfig(source: OffhandImeConfig): OffhandImeConfig {
  let defaultLlmConfig = createDefaultLlmPolishConfig();
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
      enablePrediction: source.pinyin.enablePrediction,
      enableMixedInput: source.pinyin.enableMixedInput,
      enableFuzzy: source.pinyin.enableFuzzy,
      fuzzyPairs: source.pinyin.fuzzyPairs.map((pair: string[]): string[] => pair.slice(0, 2)),
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
      providerId: source.llmPolish.providerId ? source.llmPolish.providerId : defaultLlmConfig.providerId,
      providerName: source.llmPolish.providerName ? source.llmPolish.providerName : defaultLlmConfig.providerName,
      modelPresetId: source.llmPolish.modelPresetId ? source.llmPolish.modelPresetId : defaultLlmConfig.modelPresetId,
      modelDisplayName: source.llmPolish.modelDisplayName ?
        source.llmPolish.modelDisplayName : defaultLlmConfig.modelDisplayName,
      apiModel: source.llmPolish.apiModel ? source.llmPolish.apiModel : defaultLlmConfig.apiModel,
      protocol: source.llmPolish.protocol ? source.llmPolish.protocol : defaultLlmConfig.protocol,
      endpoint: source.llmPolish.endpoint ? source.llmPolish.endpoint : defaultLlmConfig.endpoint,
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
      supportedLayouts = ['qwerty_26'];
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
  if (layout === 'voice_panel') {
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

function writeTextFile(path: string, content: string): void {
  let file = fileIo.openSync(path, fileIo.OpenMode.CREATE | fileIo.OpenMode.WRITE_ONLY | fileIo.OpenMode.TRUNC);
  try {
    fileIo.writeSync(file.fd, content);
  } finally {
    fileIo.closeSync(file);
  }
}

function readTextFileIfExists(path: string): string {
  try {
    if (!fileIo.accessSync(path)) {
      return '';
    }
  } catch (_) {
    return '';
  }
  try {
    return fileIo.readTextSync(path);
  } catch (_) {
    return '';
  }
}

function hasRequiredRimeSharedFiles(sharedDataDir: string): boolean {
  return fileExists(`${sharedDataDir}/offhand_pinyin.schema.yaml`) &&
    fileExists(`${sharedDataDir}/offhand.base.dict.yaml`) &&
    fileExists(`${sharedDataDir}/offhand_pinyin.custom.yaml`);
}

function fileExists(path: string): boolean {
  try {
    return fileIo.accessSync(path);
  } catch (_) {
    return false;
  }
}

function resetDirectoryContents(path: string): void {
  try {
    if (!fileIo.accessSync(path)) {
      ensureDirectory(path);
      return;
    }
  } catch (_) {
    ensureDirectory(path);
    return;
  }
  let entries: string[] = [];
  try {
    entries = fileIo.listFileSync(path);
  } catch (_) {
    return;
  }
  for (let index = 0; index < entries.length; index++) {
    removeRecursively(`${path}/${entries[index]}`);
  }
}

function removeRecursively(path: string): void {
  let stat: fileIo.Stat;
  try {
    stat = fileIo.lstatSync(path);
  } catch (_) {
    return;
  }
  if (stat.isDirectory()) {
    let entries: string[] = [];
    try {
      entries = fileIo.listFileSync(path);
    } catch (_) {
      entries = [];
    }
    for (let index = 0; index < entries.length; index++) {
      removeRecursively(`${path}/${entries[index]}`);
    }
    try {
      fileIo.rmdirSync(path);
    } catch (_) {
    }
    return;
  }
  try {
    fileIo.unlinkSync(path);
  } catch (_) {
  }
}

function buildRimeResourceSignature(config: OffhandImeConfig): string {
  let pageSize = Math.max(3, Math.min(12, config.input.candidatePageSize));
  let fuzzyState = config.pinyin.enableFuzzy ? '1' : '0';
  let predictionState = config.pinyin.enablePrediction ? '1' : '0';
  let fuzzyPairs = config.pinyin.fuzzyPairs.map((pair: string[]): string => pair.join('>')).join('|');
  return `${RIME_RESOURCE_VERSION}|${pageSize}|${predictionState}|${fuzzyState}|${fuzzyPairs}`;
}

function writeUtf8ResourceFile(path: string, content: string): void {
  writeTextFile(path, content);
}

function buildRimeCustomPatch(config: OffhandImeConfig): string {
  let lines: string[] = [];
  let pageSize = Math.max(3, Math.min(12, config.input.candidatePageSize));
  lines.push('patch:');
  lines.push(`  menu/page_size: ${pageSize}`);
  lines.push(`  translator/enable_sentence: ${config.pinyin.enablePrediction ? 'true' : 'false'}`);
  lines.push(`  translator/enable_completion: ${config.pinyin.enablePrediction ? 'true' : 'false'}`);
  lines.push('  speller/algebra:');
  let rules = buildSpellerAlgebra(config.pinyin.enableFuzzy, config.pinyin.fuzzyPairs);
  for (let index = 0; index < rules.length; index++) {
    lines.push(`    - ${rules[index]}`);
  }
  return `${lines.join('\n')}\n`;
}

function buildSpellerAlgebra(enableFuzzy: boolean, fuzzyPairs: string[][]): string[] {
  let rules = DEFAULT_SPELLER_ALGEBRA.slice();
  if (!enableFuzzy) {
    return rules;
  }
  let extraRules: string[] = [];
  for (let index = 0; index < fuzzyPairs.length; index++) {
    let pair = fuzzyPairs[index];
    if (!Array.isArray(pair) || pair.length < 2) {
      continue;
    }
    appendFuzzyRules(extraRules, normalizeToken(pair[0]), normalizeToken(pair[1]));
  }
  for (let index = 0; index < extraRules.length; index++) {
    if (rules.indexOf(extraRules[index]) < 0) {
      rules.push(extraRules[index]);
    }
  }
  return rules;
}

function appendFuzzyRules(rules: string[], left: string, right: string): void {
  if (left.length === 0 || right.length === 0 || left === right) {
    return;
  }
  if (isPair(left, right, 'z', 'zh')) {
    pushRules(rules, ['derive/^z(.*)$/zh$1/', 'derive/^zh(.*)$/z$1/']);
    return;
  }
  if (isPair(left, right, 'c', 'ch')) {
    pushRules(rules, ['derive/^c(.*)$/ch$1/', 'derive/^ch(.*)$/c$1/']);
    return;
  }
  if (isPair(left, right, 's', 'sh')) {
    pushRules(rules, ['derive/^s(.*)$/sh$1/', 'derive/^sh(.*)$/s$1/']);
    return;
  }
  if (isPair(left, right, 'l', 'n')) {
    pushRules(rules, ['derive/^l(.*)$/n$1/', 'derive/^n(.*)$/l$1/']);
    return;
  }
  if (isPair(left, right, 'f', 'h')) {
    pushRules(rules, ['derive/^f(.*)$/h$1/', 'derive/^h(.*)$/f$1/']);
    return;
  }
  if (isPair(left, right, 'an', 'ang')) {
    pushRules(rules, ['derive/an$/ang/', 'derive/ang$/an/']);
    return;
  }
  if (isPair(left, right, 'en', 'eng')) {
    pushRules(rules, ['derive/en$/eng/', 'derive/eng$/en/']);
    return;
  }
  if (isPair(left, right, 'in', 'ing')) {
    pushRules(rules, ['derive/in$/ing/', 'derive/ing$/in/']);
    return;
  }
  if (isPair(left, right, 'ian', 'iang')) {
    pushRules(rules, ['derive/ian$/iang/', 'derive/iang$/ian/']);
    return;
  }
  if (isPair(left, right, 'uan', 'uang')) {
    pushRules(rules, ['derive/uan$/uang/', 'derive/uang$/uan/']);
    return;
  }
  if (isPair(left, right, 'u', 'ou')) {
    pushRules(rules, ['derive/u$/ou/', 'derive/ou$/u/']);
    return;
  }
  if (isPair(left, right, 'ue', 've') || isPair(left, right, 'u', 'v')) {
    pushRules(rules, ['derive/^([nl])ve$/$1ue/', 'derive/^([nl])ue$/$1ve/', 'derive/^([jqxy])u/$1v/']);
  }
}

function pushRules(target: string[], values: string[]): void {
  for (let index = 0; index < values.length; index++) {
    if (target.indexOf(values[index]) < 0) {
      target.push(values[index]);
    }
  }
}

function isPair(left: string, right: string, a: string, b: string): boolean {
  return (left === a && right === b) || (left === b && right === a);
}

function normalizeToken(value: string): string {
  return value.trim().toLowerCase();
}
