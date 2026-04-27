import { common } from '@kit.AbilityKit';
import { preferences } from '@kit.ArkData';
import { hilog } from '@kit.PerformanceAnalysisKit';
import contextConstant from '@ohos.app.ability.contextConstant';
import fileIo from '@ohos.file.fs';
import { KeyboardLayoutId, LetterCaseMode, OffhandRuntimeSettings } from '../ime/common/ImeTypes';
import { getDefaultBuiltinModelSelection, resolveBuiltinModelSelection } from '../ime/config/BuiltinModels';

const PREF_NAME = 'offhand_runtime_settings';
const SETTINGS_KEY = 'runtime_settings_json';
const LOG_DOMAIN = 0xFF10;
const LOG_TAG = 'OffhandSettingsStore';
const PERSISTED_SETTINGS_VERSION = 3;
const PREF_MODULE_NAME = 'entry';
const SETTINGS_FILE_DIR = 'settings';
const SETTINGS_FILE_NAME = 'offhand-runtime-settings.json';

interface PersistedRuntimeSettingsEnvelope {
  version: number;
  updatedAtMs: number;
  settings: OffhandRuntimeSettings;
}

interface RuntimeSettingsSnapshot {
  settings: OffhandRuntimeSettings;
  updatedAtMs: number;
  payload: string;
  sourceLabel: string;
}

export class OffhandSettingsStore {
  async load(context: common.Context): Promise<OffhandRuntimeSettings> {
    let canonicalContext = resolveCanonicalPreferenceContext(context);
    let fileCandidates = resolveFileContextCandidates(context, canonicalContext);
    let latestFileSnapshot = this.loadLatestFileSnapshot(fileCandidates);
    if (latestFileSnapshot) {
      this.repairFileSnapshots(fileCandidates, latestFileSnapshot);
      await this.persistSnapshot(canonicalContext, latestFileSnapshot.settings, latestFileSnapshot.updatedAtMs, 'mirror');
      hilog.info(LOG_DOMAIN, LOG_TAG,
        'load choose[%{public}s]: provider=%{public}s preset=%{public}s mode=%{public}s updatedAt=%{public}s',
        latestFileSnapshot.sourceLabel,
        latestFileSnapshot.settings.llmProviderId,
        latestFileSnapshot.settings.llmPresetId,
        latestFileSnapshot.settings.defaultEntryMode,
        String(latestFileSnapshot.updatedAtMs));
      return latestFileSnapshot.settings;
    }
    let canonicalSnapshot = await this.loadSnapshotFromContext(canonicalContext, 'canonical');
    if (canonicalSnapshot) {
      this.persistSnapshotToFileCandidates(fileCandidates, canonicalSnapshot.settings, canonicalSnapshot.updatedAtMs, 'canonical-file');
      hilog.info(LOG_DOMAIN, LOG_TAG,
        'load choose[%{public}s]: provider=%{public}s preset=%{public}s mode=%{public}s updatedAt=%{public}s',
        canonicalSnapshot.sourceLabel,
        canonicalSnapshot.settings.llmProviderId,
        canonicalSnapshot.settings.llmPresetId,
        canonicalSnapshot.settings.defaultEntryMode,
        String(canonicalSnapshot.updatedAtMs));
      return canonicalSnapshot.settings;
    }
    let legacyCandidates = resolveLegacyPreferenceContexts(context, canonicalContext);
    let legacySnapshots: RuntimeSettingsSnapshot[] = [];
    let latestLegacySnapshot: RuntimeSettingsSnapshot | undefined = undefined;
    for (let index = 0; index < legacyCandidates.length; index++) {
      let snapshot = await this.loadSnapshotFromContext(legacyCandidates[index].context, legacyCandidates[index].label);
      if (!snapshot) {
        continue;
      }
      legacySnapshots.push(snapshot);
      if (!latestLegacySnapshot || snapshot.updatedAtMs > latestLegacySnapshot.updatedAtMs) {
        latestLegacySnapshot = snapshot;
      }
    }
    if (latestLegacySnapshot) {
      this.persistSnapshotToFileCandidates(fileCandidates, latestLegacySnapshot.settings, latestLegacySnapshot.updatedAtMs, 'canonical-file');
      await this.persistSnapshot(canonicalContext, latestLegacySnapshot.settings, latestLegacySnapshot.updatedAtMs, 'migrate');
      await this.repairStaleSnapshots(legacyCandidates, legacySnapshots, latestLegacySnapshot);
      hilog.info(LOG_DOMAIN, LOG_TAG,
        'load choose[%{public}s]: provider=%{public}s preset=%{public}s mode=%{public}s updatedAt=%{public}s',
        latestLegacySnapshot.sourceLabel,
        latestLegacySnapshot.settings.llmProviderId,
        latestLegacySnapshot.settings.llmPresetId,
        latestLegacySnapshot.settings.defaultEntryMode,
        String(latestLegacySnapshot.updatedAtMs));
      return latestLegacySnapshot.settings;
    }
    hilog.warn(LOG_DOMAIN, LOG_TAG, 'load: no saved settings found, returning defaults');
    return createDefaultRuntimeSettings();
  }

  async save(context: common.Context, settings: OffhandRuntimeSettings): Promise<void> {
    let normalized = cloneRuntimeSettings(settings);
    let updatedAtMs = Date.now();
    let canonicalContext = resolveCanonicalPreferenceContext(context);
    let fileCandidates = resolveFileContextCandidates(context, canonicalContext);
    this.persistSnapshotToFileCandidates(fileCandidates, normalized, updatedAtMs, 'save-file');
    await this.persistSnapshot(canonicalContext, normalized, updatedAtMs, 'save');
  }

  async reset(context: common.Context): Promise<OffhandRuntimeSettings> {
    let defaults = createDefaultRuntimeSettings();
    await this.save(context, defaults);
    return defaults;
  }

  private loadLatestFileSnapshot(candidates: PreferenceContextCandidate[]): RuntimeSettingsSnapshot | undefined {
    let latestSnapshot: RuntimeSettingsSnapshot | undefined = undefined;
    for (let index = 0; index < candidates.length; index++) {
      let snapshot = this.loadSnapshotFromFile(candidates[index].context, candidates[index].label);
      if (!snapshot) {
        continue;
      }
      if (!latestSnapshot || snapshot.updatedAtMs > latestSnapshot.updatedAtMs) {
        latestSnapshot = snapshot;
      }
    }
    return latestSnapshot;
  }

  private async loadSnapshotFromContext(context: common.Context, sourceLabel: string): Promise<RuntimeSettingsSnapshot | undefined> {
    try {
      hilog.info(LOG_DOMAIN, LOG_TAG,
        'context[%{public}s] area=%{public}d process=%{public}s prefsDir=%{public}s filesDir=%{public}s',
        sourceLabel, context.area, context.processName, context.preferencesDir, context.filesDir);
      try {
        await preferences.removePreferencesFromCache(context, PREF_NAME);
      } catch (_) {
      }
      let preference = await preferences.getPreferences(context, PREF_NAME);
      let raw = await preference.get(SETTINGS_KEY, '') as string;
      let rawLen = typeof raw === 'string' ? raw.length : -1;
      hilog.info(LOG_DOMAIN, LOG_TAG, 'load[%{public}s] rawLen=%{public}d', sourceLabel, rawLen);
      if (typeof raw !== 'string' || raw.trim().length === 0) {
        return undefined;
      }
      let snapshot = parseRuntimeSettingsSnapshot(raw, sourceLabel);
      hilog.info(LOG_DOMAIN, LOG_TAG,
        'load hit[%{public}s]: provider=%{public}s preset=%{public}s apiKeyLen=%{public}d mode=%{public}s updatedAt=%{public}s',
        sourceLabel,
        snapshot.settings.llmProviderId,
        snapshot.settings.llmPresetId,
        snapshot.settings.llmApiKey.length,
        snapshot.settings.defaultEntryMode,
        String(snapshot.updatedAtMs));
      return snapshot;
    } catch (error) {
      hilog.warn(LOG_DOMAIN, LOG_TAG, 'load[%{public}s] failed: %{public}s',
        sourceLabel, (error as Error).message ?? String(error));
      return undefined;
    }
  }

  private async persistSnapshot(context: common.Context,
    settings: OffhandRuntimeSettings,
    updatedAtMs: number,
    sourceLabel: string): Promise<void> {
    let payload = serializeRuntimeSettingsPayload(settings, updatedAtMs);
    try {
      hilog.info(LOG_DOMAIN, LOG_TAG,
        'context[%{public}s] area=%{public}d process=%{public}s prefsDir=%{public}s filesDir=%{public}s',
        sourceLabel, context.area, context.processName, context.preferencesDir, context.filesDir);
      let preference = await preferences.getPreferences(context, PREF_NAME);
      await preference.put(SETTINGS_KEY, payload);
      await preference.flush();
      hilog.info(LOG_DOMAIN, LOG_TAG,
        '%{public}s[%{public}s] apiKeyLen=%{public}d mode=%{public}s updatedAt=%{public}s',
        sourceLabel,
        sourceLabel === 'save' ? 'canonical' : sourceLabel,
        settings.llmApiKey.length,
        settings.defaultEntryMode,
        String(updatedAtMs));
    } catch (error) {
      hilog.warn(LOG_DOMAIN, LOG_TAG, '%{public}s[%{public}s] failed: %{public}s',
        sourceLabel, sourceLabel === 'save' ? 'canonical' : sourceLabel,
        (error as Error).message ?? String(error));
      throw new Error((error as Error).message ?? String(error));
    }
  }

  private loadSnapshotFromFile(context: common.Context, sourceLabel: string): RuntimeSettingsSnapshot | undefined {
    let path = resolveSettingsFilePath(context);
    hilog.info(LOG_DOMAIN, LOG_TAG,
      'file[%{public}s] path=%{public}s area=%{public}d process=%{public}s filesDir=%{public}s',
      sourceLabel, path, context.area, context.processName, context.filesDir);
    let raw = readTextFileIfExists(path);
    let rawLen = raw.length;
    hilog.info(LOG_DOMAIN, LOG_TAG, 'load[%{public}s] rawLen=%{public}d', sourceLabel, rawLen);
    if (rawLen === 0) {
      return undefined;
    }
    let snapshot = parseRuntimeSettingsSnapshot(raw, sourceLabel);
    hilog.info(LOG_DOMAIN, LOG_TAG,
      'load hit[%{public}s]: provider=%{public}s preset=%{public}s apiKeyLen=%{public}d mode=%{public}s updatedAt=%{public}s',
      sourceLabel,
      snapshot.settings.llmProviderId,
      snapshot.settings.llmPresetId,
      snapshot.settings.llmApiKey.length,
      snapshot.settings.defaultEntryMode,
      String(snapshot.updatedAtMs));
    return snapshot;
  }

  private persistSnapshotToFile(context: common.Context,
    settings: OffhandRuntimeSettings,
    updatedAtMs: number,
    sourceLabel: string): void {
    let path = resolveSettingsFilePath(context);
    let payload = serializeRuntimeSettingsPayload(settings, updatedAtMs);
    try {
      ensureDirectory(resolveSettingsFileDirectory(context));
      writeTextFile(path, payload);
      hilog.info(LOG_DOMAIN, LOG_TAG,
        '%{public}s[%{public}s] apiKeyLen=%{public}d mode=%{public}s updatedAt=%{public}s path=%{public}s',
        sourceLabel,
        sourceLabel === 'save-file' ? 'canonical-file' : sourceLabel,
        settings.llmApiKey.length,
        settings.defaultEntryMode,
        String(updatedAtMs),
        path);
    } catch (error) {
      hilog.warn(LOG_DOMAIN, LOG_TAG, '%{public}s[%{public}s] failed: %{public}s',
        sourceLabel, sourceLabel === 'save-file' ? 'canonical-file' : sourceLabel,
        (error as Error).message ?? String(error));
    }
  }

  private persistSnapshotToFileCandidates(candidates: PreferenceContextCandidate[],
    settings: OffhandRuntimeSettings,
    updatedAtMs: number,
    sourceLabel: string): void {
    for (let index = 0; index < candidates.length; index++) {
      this.persistSnapshotToFile(candidates[index].context, settings, updatedAtMs, `${sourceLabel}:${candidates[index].label}`);
    }
  }

  private repairFileSnapshots(candidates: PreferenceContextCandidate[], latestSnapshot: RuntimeSettingsSnapshot): void {
    let normalizedUpdatedAtMs = latestSnapshot.updatedAtMs > 0 ? latestSnapshot.updatedAtMs : Date.now();
    this.persistSnapshotToFileCandidates(candidates, latestSnapshot.settings, normalizedUpdatedAtMs, 'repair-file');
  }

  private async repairStaleSnapshots(candidates: PreferenceContextCandidate[],
    snapshots: RuntimeSettingsSnapshot[],
    latestSnapshot: RuntimeSettingsSnapshot): Promise<void> {
    let normalizedUpdatedAtMs = latestSnapshot.updatedAtMs > 0 ? latestSnapshot.updatedAtMs : Date.now();
    let canonicalPayload = serializeRuntimeSettingsPayload(latestSnapshot.settings, normalizedUpdatedAtMs);
    let needsRepair = latestSnapshot.updatedAtMs === 0 || snapshots.length !== candidates.length;
    if (!needsRepair) {
      for (let index = 0; index < snapshots.length; index++) {
        if (snapshots[index].payload !== canonicalPayload) {
          needsRepair = true;
          break;
        }
      }
    }
    if (!needsRepair) {
      return;
    }
    for (let index = 0; index < candidates.length; index++) {
      let ctx = candidates[index].context;
      let sourceLabel = candidates[index].label;
      try {
        try {
          await preferences.removePreferencesFromCache(ctx, PREF_NAME);
        } catch (_) {
        }
        let preference = await preferences.getPreferences(ctx, PREF_NAME);
        await preference.put(SETTINGS_KEY, canonicalPayload);
        await preference.flush();
        hilog.info(LOG_DOMAIN, LOG_TAG,
          'repair[%{public}s] mode=%{public}s updatedAt=%{public}s',
          sourceLabel, latestSnapshot.settings.defaultEntryMode, String(normalizedUpdatedAtMs));
      } catch (error) {
        hilog.warn(LOG_DOMAIN, LOG_TAG, 'repair[%{public}s] failed: %{public}s',
          sourceLabel, (error as Error).message ?? String(error));
      }
    }
  }
}

interface PreferenceContextCandidate {
  context: common.Context;
  label: string;
}

function resolveCanonicalPreferenceContext(context: common.Context): common.Context {
  try {
    let moduleContext = context.createModuleContext(PREF_MODULE_NAME);
    return moduleContext.createAreaModeContext(contextConstant.AreaMode.EL2);
  } catch (_) {
  }
  try {
    let appContext = context.getApplicationContext();
    if (appContext) {
      try {
        let moduleContext = appContext.createModuleContext(PREF_MODULE_NAME);
        return moduleContext.createAreaModeContext(contextConstant.AreaMode.EL2);
      } catch (_) {
        try {
          return appContext.createAreaModeContext(contextConstant.AreaMode.EL2);
        } catch (_) {
          return appContext;
        }
      }
    }
  } catch (_) {
  }
  try {
    return context.createAreaModeContext(contextConstant.AreaMode.EL2);
  } catch (_) {
  }
  return context;
}

function resolveLegacyPreferenceContexts(context: common.Context,
  canonicalContext: common.Context): PreferenceContextCandidate[] {
  let candidates: PreferenceContextCandidate[] = [];
  tryPushContextCandidate(candidates, context, 'legacy-current', canonicalContext);
  try {
    let appContext = context.getApplicationContext();
    if (appContext) {
      tryPushContextCandidate(candidates, appContext, 'legacy-app', canonicalContext);
    }
  } catch (_) {
  }
  return candidates;
}

function resolveFileContextCandidates(context: common.Context,
  canonicalContext: common.Context): PreferenceContextCandidate[] {
  let candidates: PreferenceContextCandidate[] = [];
  tryPushFileContextCandidate(candidates, context, 'source');
  try {
    let moduleContext = context.createModuleContext(PREF_MODULE_NAME);
    tryPushFileContextCandidate(candidates, moduleContext, 'module');
  } catch (_) {
  }
  tryPushFileContextCandidate(candidates, canonicalContext, 'canonical');
  try {
    let appContext = context.getApplicationContext();
    if (appContext) {
      tryPushFileContextCandidate(candidates, appContext, 'app');
      try {
        let appModuleContext = appContext.createModuleContext(PREF_MODULE_NAME);
        tryPushFileContextCandidate(candidates, appModuleContext, 'app-module');
      } catch (_) {
      }
    }
  } catch (_) {
  }
  return candidates;
}

function tryPushContextCandidate(candidates: PreferenceContextCandidate[],
  context: common.Context,
  label: string,
  canonicalContext: common.Context): void {
  if (isSamePreferenceContext(context, canonicalContext)) {
    return;
  }
  for (let index = 0; index < candidates.length; index++) {
    if (isSamePreferenceContext(candidates[index].context, context)) {
      return;
    }
  }
  candidates.push({
    context: context,
    label: label
  });
}

function isSamePreferenceContext(left: common.Context, right: common.Context): boolean {
  return left.preferencesDir === right.preferencesDir && left.filesDir === right.filesDir;
}

function tryPushFileContextCandidate(candidates: PreferenceContextCandidate[],
  context: common.Context,
  label: string): void {
  for (let index = 0; index < candidates.length; index++) {
    if (candidates[index].context.filesDir === context.filesDir) {
      return;
    }
  }
  candidates.push({
    context: context,
    label: label
  });
}

function resolveSettingsFileDirectory(context: common.Context): string {
  return `${context.filesDir}/${SETTINGS_FILE_DIR}`;
}

function resolveSettingsFilePath(context: common.Context): string {
  return `${resolveSettingsFileDirectory(context)}/${SETTINGS_FILE_NAME}`;
}

function ensureDirectory(path: string): void {
  try {
    if (fileIo.accessSync(path)) {
      return;
    }
  } catch (_) {
  }
  fileIo.mkdirSync(path, true);
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

export function createDefaultRuntimeSettings(): OffhandRuntimeSettings {
  let defaultSelection = getDefaultBuiltinModelSelection();
  return {
    enablePreviewText: true,
    enableVoice: true,
    enableBuiltinAsr: true,
    enableCloudPolish: true,
    enablePersonalization: true,
    autoInsertVoiceResult: false,
    autoPolishVoiceResult: true,
    asrEndpoint: '',
    llmProviderId: defaultSelection.provider.providerId,
    llmPresetId: defaultSelection.preset.presetId,
    llmApiKey: '',
    llmStyle: 'clean_conversational',
    defaultEntryMode: 'keyboard',
    defaultSubtypeId: 'zh-Hans-pinyin',
    defaultKeyboardLayout: 'qwerty_26',
    defaultLetterCase: 'lower'
  };
}

export function cloneRuntimeSettings(source: OffhandRuntimeSettings): OffhandRuntimeSettings {
  let selection = resolveBuiltinModelSelection(source.llmProviderId, source.llmPresetId);
  let entryMode = normalizeEntryMode(source.defaultEntryMode);
  return {
    enablePreviewText: source.enablePreviewText,
    enableVoice: source.enableVoice,
    enableBuiltinAsr: source.enableBuiltinAsr,
    enableCloudPolish: source.enableCloudPolish,
    enablePersonalization: source.enablePersonalization,
    autoInsertVoiceResult: source.autoInsertVoiceResult,
    autoPolishVoiceResult: source.autoPolishVoiceResult,
    asrEndpoint: source.asrEndpoint,
    llmProviderId: selection.provider.providerId,
    llmPresetId: selection.preset.presetId,
    llmApiKey: typeof source.llmApiKey === 'string' ? source.llmApiKey.trim() : '',
    llmStyle: source.llmStyle,
    defaultEntryMode: entryMode,
    defaultSubtypeId: normalizeDefaultSubtypeId(source.defaultSubtypeId, entryMode),
    defaultKeyboardLayout: normalizeDefaultKeyboardLayout(source.defaultKeyboardLayout, entryMode),
    defaultLetterCase: normalizeDefaultLetterCase(source.defaultLetterCase)
  };
}

function serializeRuntimeSettingsPayload(settings: OffhandRuntimeSettings, updatedAtMs: number): string {
  let envelope: PersistedRuntimeSettingsEnvelope = {
    version: PERSISTED_SETTINGS_VERSION,
    updatedAtMs: normalizeUpdatedAtMs(updatedAtMs),
    settings: cloneRuntimeSettings(settings)
  };
  return JSON.stringify(envelope);
}

function parseRuntimeSettingsSnapshot(raw: string, sourceLabel: string): RuntimeSettingsSnapshot {
  let envelope = parseRuntimeSettingsEnvelope(raw);
  return {
    settings: envelope.settings,
    updatedAtMs: envelope.updatedAtMs,
    payload: raw,
    sourceLabel: sourceLabel
  };
}

function parseRuntimeSettingsEnvelope(raw: string): PersistedRuntimeSettingsEnvelope {
  try {
    let parsed = JSON.parse(raw) as PersistedRuntimeSettingsEnvelope;
    if (isPersistedRuntimeSettingsEnvelope(parsed)) {
      let envelope = parsed as PersistedRuntimeSettingsEnvelope;
      return {
        version: typeof envelope.version === 'number' ? envelope.version : PERSISTED_SETTINGS_VERSION,
        updatedAtMs: normalizeUpdatedAtMs(envelope.updatedAtMs),
        settings: cloneRuntimeSettings(envelope.settings)
      };
    }
  } catch (_) {
  }
  return {
    version: 1,
    updatedAtMs: 0,
    settings: normalizeRuntimeSettings(raw)
  };
}

function isPersistedRuntimeSettingsEnvelope(value: Object | undefined): boolean {
  if (!value || typeof value !== 'object') {
    return false;
  }
  let candidate = value as PersistedRuntimeSettingsEnvelope;
  return typeof candidate.updatedAtMs === 'number' && candidate.settings !== undefined;
}

function normalizeUpdatedAtMs(value: number | undefined): number {
  if (typeof value !== 'number' || !Number.isFinite(value) || value <= 0) {
    return 0;
  }
  return Math.floor(value);
}

function normalizeEntryMode(raw: string | undefined): string {
  return raw === 'voice' ? 'voice' : 'keyboard';
}

function normalizeDefaultSubtypeId(raw: string | undefined, entryMode: string): string {
  if (typeof raw === 'string' && raw.trim().length > 0) {
    return raw.trim();
  }
  return entryMode === 'voice' ? 'zh-CN-voice' : 'zh-Hans-pinyin';
}

function normalizeDefaultKeyboardLayout(raw: KeyboardLayoutId | string | undefined, entryMode: string): KeyboardLayoutId {
  if (raw === 'qwerty_26' || raw === 't9_9' || raw === 'voice_panel') {
    return raw;
  }
  return entryMode === 'voice' ? 'voice_panel' : 'qwerty_26';
}

function normalizeDefaultLetterCase(raw: LetterCaseMode | string | undefined): LetterCaseMode {
  return raw === 'upper' ? 'upper' : 'lower';
}

function normalizeRuntimeSettings(raw: string): OffhandRuntimeSettings {
  try {
    let parsed = JSON.parse(raw) as OffhandRuntimeSettings;
    let defaults = createDefaultRuntimeSettings();
    let selection = resolveBuiltinModelSelection(parsed.llmProviderId, parsed.llmPresetId);
    let entryMode = normalizeEntryMode(parsed.defaultEntryMode);
    return {
      enablePreviewText: parsed.enablePreviewText !== undefined ? parsed.enablePreviewText : defaults.enablePreviewText,
      enableVoice: parsed.enableVoice !== undefined ? parsed.enableVoice : defaults.enableVoice,
      enableBuiltinAsr: parsed.enableBuiltinAsr !== undefined ? parsed.enableBuiltinAsr : defaults.enableBuiltinAsr,
      enableCloudPolish: parsed.enableCloudPolish !== undefined ? parsed.enableCloudPolish : defaults.enableCloudPolish,
      enablePersonalization: parsed.enablePersonalization !== undefined ?
        parsed.enablePersonalization : defaults.enablePersonalization,
      autoInsertVoiceResult: parsed.autoInsertVoiceResult !== undefined ?
        parsed.autoInsertVoiceResult : defaults.autoInsertVoiceResult,
      autoPolishVoiceResult: parsed.autoPolishVoiceResult !== undefined ?
        parsed.autoPolishVoiceResult : defaults.autoPolishVoiceResult,
      asrEndpoint: typeof parsed.asrEndpoint === 'string' ? parsed.asrEndpoint.trim() : defaults.asrEndpoint,
      llmProviderId: selection.provider.providerId,
      llmPresetId: selection.preset.presetId,
      llmApiKey: typeof parsed.llmApiKey === 'string' ? parsed.llmApiKey.trim() : defaults.llmApiKey,
      llmStyle: typeof parsed.llmStyle === 'string' && parsed.llmStyle.trim().length > 0 ?
        parsed.llmStyle.trim() : defaults.llmStyle,
      defaultEntryMode: entryMode,
      defaultSubtypeId: normalizeDefaultSubtypeId(parsed.defaultSubtypeId, entryMode),
      defaultKeyboardLayout: normalizeDefaultKeyboardLayout(parsed.defaultKeyboardLayout, entryMode),
      defaultLetterCase: normalizeDefaultLetterCase(parsed.defaultLetterCase)
    };
  } catch (_) {
    return createDefaultRuntimeSettings();
  }
}
