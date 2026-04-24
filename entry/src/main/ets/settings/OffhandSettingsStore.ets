import { common } from '@kit.AbilityKit';
import { preferences } from '@kit.ArkData';
import { hilog } from '@kit.PerformanceAnalysisKit';
import fileIo from '@ohos.file.fs';
import { OffhandRuntimeSettings } from '../ime/common/ImeTypes';
import { getDefaultBuiltinModelSelection, resolveBuiltinModelSelection } from '../ime/config/BuiltinModels';

const PREF_NAME = 'offhand_runtime_settings';
const SETTINGS_KEY = 'runtime_settings_json';
const LOG_DOMAIN = 0xFF10;
const LOG_TAG = 'OffhandSettingsStore';

export class OffhandSettingsStore {
  async load(context: common.Context): Promise<OffhandRuntimeSettings> {
    let contexts = resolvePreferenceContexts(context);
    hilog.info(LOG_DOMAIN, LOG_TAG, 'load enter: contexts=%{public}d', contexts.length);
    // Try the shared application-level preferences first so IME extension and
    // settings UIAbility see the same file. If that file is empty (e.g. the
    // user saved under an earlier build that wrote to the ability-scoped
    // preferences dir), fall back to the ability context so we don't lose
    // their previously-entered API key.
    for (let index = 0; index < contexts.length; index++) {
      let ctx = contexts[index];
      let label = describeContext(ctx, index);
      probeFilesDir(ctx, label);
      try {
        // `preferences.getPreferences` returns an in-process cached singleton.
        // When another process (the settings UIAbility) writes to the same
        // file on disk, this process still serves stale values from its
        // cache. Evict the cached entry so we re-read from disk every load.
        try {
          await preferences.removePreferencesFromCache(ctx, PREF_NAME);
        } catch (_) {
        }
        let preference = await preferences.getPreferences(ctx, PREF_NAME);
        let raw = await preference.get(SETTINGS_KEY, '') as string;
        let rawLen = typeof raw === 'string' ? raw.length : -1;
        hilog.info(LOG_DOMAIN, LOG_TAG, 'load ctx=%{public}s rawLen=%{public}d',
          label, rawLen);
        if (typeof raw === 'string' && raw.trim().length > 0) {
          let normalized = normalizeRuntimeSettings(raw);
          hilog.info(LOG_DOMAIN, LOG_TAG,
            'load hit: ctx=%{public}s provider=%{public}s preset=%{public}s apiKeyLen=%{public}d',
            label, normalized.llmProviderId, normalized.llmPresetId, normalized.llmApiKey.length);
          return normalized;
        }
      } catch (error) {
        hilog.warn(LOG_DOMAIN, LOG_TAG, 'load ctx=%{public}s failed: %{public}s',
          label, (error as Error).message ?? String(error));
      }
    }
    hilog.warn(LOG_DOMAIN, LOG_TAG, 'load: no saved settings found, returning defaults');
    return createDefaultRuntimeSettings();
  }

  async save(context: common.Context, settings: OffhandRuntimeSettings): Promise<void> {
    let normalized = cloneRuntimeSettings(settings);
    let payload = JSON.stringify(normalized);
    // Write to every resolvable context so old builds that read from the
    // ability-scoped dir still see the latest values, and new builds that
    // read from the application-scoped dir also do.
    let contexts = resolvePreferenceContexts(context);
    let succeeded = 0;
    for (let index = 0; index < contexts.length; index++) {
      let ctx = contexts[index];
      let label = describeContext(ctx, index);
      try {
        let preference = await preferences.getPreferences(ctx, PREF_NAME);
        await preference.put(SETTINGS_KEY, payload);
        await preference.flush();
        succeeded += 1;
        hilog.info(LOG_DOMAIN, LOG_TAG, 'save ctx=%{public}s apiKeyLen=%{public}d',
          label, normalized.llmApiKey.length);
      } catch (error) {
        hilog.warn(LOG_DOMAIN, LOG_TAG, 'save ctx=%{public}s failed: %{public}s',
          label, (error as Error).message ?? String(error));
      }
    }
    if (succeeded === 0) {
      throw new Error('preferences save failed on all contexts');
    }
  }

  async reset(context: common.Context): Promise<OffhandRuntimeSettings> {
    let defaults = createDefaultRuntimeSettings();
    await this.save(context, defaults);
    return defaults;
  }
}

function describeContext(ctx: common.Context, index: number): string {
  try {
    let dir = ctx.preferencesDir;
    if (typeof dir === 'string' && dir.length > 0) {
      return `${index}:${dir}`;
    }
  } catch (_) {
  }
  return `${index}`;
}

// Direct file-system probe so we can distinguish "preferences cache bug" from
// "sandbox not shared": logs whether the preferences file actually exists on
// disk from this process's POV, its size, and the on-disk content length.
// If the file the settings UIAbility just wrote is missing here, the two
// abilities run in separate sandboxes and we need a shared-storage mechanism
// (dataGroupId, DataShare, etc.).
function probeFilesDir(ctx: common.Context, label: string): void {
  try {
    let dir = ctx.preferencesDir;
    if (typeof dir !== 'string' || dir.length === 0) {
      return;
    }
    let candidate = `${dir}/${PREF_NAME}`;
    let exists = fileIo.accessSync(candidate);
    if (!exists) {
      hilog.info(LOG_DOMAIN, LOG_TAG, 'probe ctx=%{public}s file_missing path=%{public}s',
        label, candidate);
      return;
    }
    let stat = fileIo.statSync(candidate);
    hilog.info(LOG_DOMAIN, LOG_TAG, 'probe ctx=%{public}s file_size=%{public}d path=%{public}s',
      label, stat.size, candidate);
  } catch (error) {
    hilog.warn(LOG_DOMAIN, LOG_TAG, 'probe ctx=%{public}s failed: %{public}s',
      label, (error as Error).message ?? String(error));
  }
}

// Preferences are stored under `context.preferencesDir`, which differs between
// the settings UIAbility (Index page) and the InputMethodExtensionAbility that
// hosts the IME. Return both the shared application context (preferred) and
// the original ability context so load falls back and save mirrors across
// them — this avoids losing values saved under an older build that only wrote
// to the ability context.
function resolvePreferenceContexts(context: common.Context): common.Context[] {
  let contexts: common.Context[] = [];
  try {
    let appContext = context.getApplicationContext();
    if (appContext) {
      contexts.push(appContext);
    }
  } catch (_) {
  }
  if (contexts.indexOf(context) < 0) {
    contexts.push(context);
  }
  return contexts;
}

export function createDefaultRuntimeSettings(): OffhandRuntimeSettings {
  let defaultSelection = getDefaultBuiltinModelSelection();
  return {
    enablePreviewText: true,
    enableVoice: true,
    enableCloudPolish: true,
    enablePersonalization: true,
    autoInsertVoiceResult: false,
    autoPolishVoiceResult: true,
    asrEndpoint: '',
    llmProviderId: defaultSelection.provider.providerId,
    llmPresetId: defaultSelection.preset.presetId,
    llmApiKey: '',
    llmStyle: 'clean_conversational',
    defaultEntryMode: 'keyboard'
  };
}

export function cloneRuntimeSettings(source: OffhandRuntimeSettings): OffhandRuntimeSettings {
  let selection = resolveBuiltinModelSelection(source.llmProviderId, source.llmPresetId);
  return {
    enablePreviewText: source.enablePreviewText,
    enableVoice: source.enableVoice,
    enableCloudPolish: source.enableCloudPolish,
    enablePersonalization: source.enablePersonalization,
    autoInsertVoiceResult: source.autoInsertVoiceResult,
    autoPolishVoiceResult: source.autoPolishVoiceResult,
    asrEndpoint: source.asrEndpoint,
    llmProviderId: selection.provider.providerId,
    llmPresetId: selection.preset.presetId,
    llmApiKey: typeof source.llmApiKey === 'string' ? source.llmApiKey.trim() : '',
    llmStyle: source.llmStyle,
    defaultEntryMode: normalizeEntryMode(source.defaultEntryMode)
  };
}

function normalizeEntryMode(raw: string | undefined): string {
  return raw === 'voice' ? 'voice' : 'keyboard';
}

function normalizeRuntimeSettings(raw: string): OffhandRuntimeSettings {
  try {
    let parsed = JSON.parse(raw) as OffhandRuntimeSettings;
    let defaults = createDefaultRuntimeSettings();
    let selection = resolveBuiltinModelSelection(parsed.llmProviderId, parsed.llmPresetId);
    return {
      enablePreviewText: parsed.enablePreviewText !== undefined ? parsed.enablePreviewText : defaults.enablePreviewText,
      enableVoice: parsed.enableVoice !== undefined ? parsed.enableVoice : defaults.enableVoice,
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
      defaultEntryMode: normalizeEntryMode(parsed.defaultEntryMode)
    };
  } catch (_) {
    return createDefaultRuntimeSettings();
  }
}
