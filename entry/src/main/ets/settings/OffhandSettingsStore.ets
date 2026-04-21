import { common } from '@kit.AbilityKit';
import { preferences } from '@kit.ArkData';
import { OffhandRuntimeSettings } from '../ime/common/ImeTypes';

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
  return {
    enablePreviewText: true,
    enableVoice: true,
    enableCloudPolish: true,
    enablePersonalization: true,
    autoInsertVoiceResult: false,
    autoPolishVoiceResult: true,
    asrEndpoint: '',
    llmEndpoint: '',
    llmStyle: 'clean_conversational'
  };
}

export function cloneRuntimeSettings(source: OffhandRuntimeSettings): OffhandRuntimeSettings {
  return {
    enablePreviewText: source.enablePreviewText,
    enableVoice: source.enableVoice,
    enableCloudPolish: source.enableCloudPolish,
    enablePersonalization: source.enablePersonalization,
    autoInsertVoiceResult: source.autoInsertVoiceResult,
    autoPolishVoiceResult: source.autoPolishVoiceResult,
    asrEndpoint: source.asrEndpoint,
    llmEndpoint: source.llmEndpoint,
    llmStyle: source.llmStyle
  };
}

function normalizeRuntimeSettings(raw: string): OffhandRuntimeSettings {
  try {
    let parsed = JSON.parse(raw) as OffhandRuntimeSettings;
    let defaults = createDefaultRuntimeSettings();
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
      llmEndpoint: typeof parsed.llmEndpoint === 'string' ? parsed.llmEndpoint.trim() : defaults.llmEndpoint,
      llmStyle: typeof parsed.llmStyle === 'string' && parsed.llmStyle.trim().length > 0 ?
        parsed.llmStyle.trim() : defaults.llmStyle
    };
  } catch (_) {
    return createDefaultRuntimeSettings();
  }
}
