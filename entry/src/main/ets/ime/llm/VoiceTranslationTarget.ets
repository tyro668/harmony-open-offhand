export const DEFAULT_VOICE_TRANSLATION_TARGET_LANGUAGE: string = 'en';

export interface VoiceTranslationTarget {
  id: string;
  label: string;
  promptName: string;
}

const VOICE_TRANSLATION_TARGETS: VoiceTranslationTarget[] = [
  { id: 'en', label: '英文', promptName: '英文' },
  { id: 'ja', label: '日文', promptName: '日文' },
  { id: 'ru', label: '俄文', promptName: '俄文' },
  { id: 'ko', label: '韩文', promptName: '韩文' },
  { id: 'vi', label: '越南文', promptName: '越南文' },
  { id: 'fr', label: '法文', promptName: '法文' },
  { id: 'de', label: '德文', promptName: '德文' }
];

export function listVoiceTranslationTargets(): VoiceTranslationTarget[] {
  return VOICE_TRANSLATION_TARGETS;
}

export function normalizeVoiceTranslationTarget(raw: string | undefined): string {
  if (!raw || raw.trim().length === 0) {
    return DEFAULT_VOICE_TRANSLATION_TARGET_LANGUAGE;
  }
  let normalized = raw.trim().toLowerCase();
  for (let index = 0; index < VOICE_TRANSLATION_TARGETS.length; index++) {
    if (VOICE_TRANSLATION_TARGETS[index].id === normalized) {
      return normalized;
    }
  }
  return DEFAULT_VOICE_TRANSLATION_TARGET_LANGUAGE;
}

export function resolveVoiceTranslationTarget(raw: string | undefined): VoiceTranslationTarget {
  let normalized = normalizeVoiceTranslationTarget(raw);
  for (let index = 0; index < VOICE_TRANSLATION_TARGETS.length; index++) {
    if (VOICE_TRANSLATION_TARGETS[index].id === normalized) {
      return VOICE_TRANSLATION_TARGETS[index];
    }
  }
  return VOICE_TRANSLATION_TARGETS[0];
}
