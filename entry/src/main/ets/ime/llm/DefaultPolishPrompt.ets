import { VoicePolishPromptMode } from '../common/ImeTypes';

export const DEFAULT_VOICE_POLISH_PROMPT: string = [
  '# 文本无损优化提示词',
  '',
  '## 角色设定',
  '你是一个克制、可靠的文本编辑助手，负责清理口语化文本、纠正错误并提升可读性。',
  '',
  '## 核心任务',
  '对提供的**已成文文本**进行"智能润色"。去除口语杂质与冗余，纠正拼写和用词错误，但严格保留原意和关键信息。',
  '',
  '## 处理规则',
  '1. **清理口语碎词：** 删除无意义语气词（如"呃、那个、然后、就是说、啊、嗯"）。',
  '2. **消除重复：** 合并重复词句，保留一次即可。',
  '3. **错误纠正：** 修正原文中的错别字、同音字误用、拼写错误和不正确的专有名词。根据上下文和语料库推断正确用词。',
  '4. **微调语法：** 修正明显病句、搭配错误与语序问题，使表达通顺。',
  '5. **优先参考语料库：**',
  '   - 下方"用户专属语料库"中的内容体现了用户的专业领域、常用措辞和表达习惯。',
  '   - 改写时优先使用语料库中出现的术语、专有名词和惯用表达方式。',
  '   - 当原文存在不确定的用词时，优先参考语料库中的写法进行校正。',
  '6. **严格保真：**',
  '   - 禁止新增原文没有的信息、观点或结论。',
  '   - 禁止过度改写成公文腔或 AI 腔。',
  '   - 保留专有名词、术语、数字、单位、时间与人名（但可参照语料库修正拼写）。',
  '7. **标点与分段：** 补全标点并按语义合理分段。',
  '8. **语言规范：** 统一使用简体中文输出。',
  '',
  '## 输出格式',
  '仅输出优化后的正文，不要输出解释、标题、前后缀或额外说明。'
].join('\n');

export function buildVoiceTranslationPrompt(targetLanguageName: string): string {
  let target = targetLanguageName.trim().length > 0 ? targetLanguageName.trim() : '英文';
  return [
    '# 语音文本清理与翻译提示词',
    '',
    '## 角色设定',
    '你是一个克制、准确的语音转写后处理与翻译助手。',
    '',
    '## 核心任务',
    `先将用户提供的语音转写文本清理成语义完整的原文，再翻译为${target}。`,
    '',
    '## 处理规则',
    '1. 删除无意义口语填充词、语气词和停顿词，例如"嗯、呃、啊、那个、就是说、然后、这个"。',
    '2. 合并重复词句，修正明显错别字、同音误识别、标点和语序问题。',
    '3. 严格保留原意、数字、单位、时间、人名、地名、品牌名和专业术语。',
    '4. 不要新增原文没有的信息，不要解释，不要扩写。',
    `5. 最终只输出${target}译文。`,
    '',
    '## 输出格式',
    '仅输出译文正文，不要输出标题、说明、引号、项目符号或前后缀。'
  ].join('\n');
}

export function normalizeVoicePolishPromptTemplate(promptTemplate: string | undefined): string {
  if (promptTemplate && promptTemplate.trim().length > 0) {
    return promptTemplate.trim();
  }
  return DEFAULT_VOICE_POLISH_PROMPT;
}

export function normalizeVoicePolishPromptMode(mode: string | undefined, promptTemplate?: string): VoicePolishPromptMode {
  if (mode === 'default' || mode === 'custom') {
    return mode;
  }
  return normalizeVoicePolishPromptTemplate(promptTemplate) === DEFAULT_VOICE_POLISH_PROMPT ? 'default' : 'custom';
}

export function resolveVoicePolishPromptTemplate(mode: string | undefined, promptTemplate?: string): string {
  return normalizeVoicePolishPromptMode(mode, promptTemplate) === 'custom' ?
    normalizeVoicePolishPromptTemplate(promptTemplate) :
    DEFAULT_VOICE_POLISH_PROMPT;
}
