import { common } from '@kit.AbilityKit';
import { preferences } from '@kit.ArkData';
import { OffhandRuntimeSettings } from '../ime/common/ImeTypes';
import { getDefaultBuiltinModelSelection, resolveBuiltinModelSelection } from '../ime/config/BuiltinModels';

const PREF_NAME = 'offhand_runtime_settings';
const SETTINGS_KEY = 'runtime_settings_json';

export class OffhandSettingsStore {
  async load(context: common.Context): Promise<OffhandRuntimeSettings> {
    try {
      let preference = await preferences.getPreferences(context, PREF_NAME);
      let raw = await preference.get(SETTINGS_KEY, '') as string;
      if (typeof raw !== 'string' || raw.trim().length === 0) {
        return createDefaultRuntimeSettings();
      }
      return normalizeRuntimeSettings(raw);
    } catch (_) {
      return createDefaultRuntimeSettings();
    }
  }

  async save(context: common.Context, settings: OffhandRuntimeSettings): Promise<void> {
    let preference = await preferences.getPreferences(context, PREF_NAME);
    let normalized = cloneRuntimeSettings(settings);
    await preference.put(SETTINGS_KEY, JSON.stringify(normalized));
    await preference.flush();
  }

  async reset(context: common.Context): Promise<OffhandRuntimeSettings> {
    let defaults = createDefaultRuntimeSettings();
    await this.save(context, defaults);
    return defaults;
  }
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
