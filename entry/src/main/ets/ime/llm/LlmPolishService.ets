import { RemoteHttpClient } from '../network/RemoteHttpClient';
import { OffhandLlmPolishConfig } from '../common/ImeTypes';

export interface LlmPolishRequest {
  text: string;
  locale: string;
  subtypeId: string;
  style: string;
}

export interface LlmPolishResult {
  text: string;
  source: 'remote_llm' | 'local_fallback';
  provider: string;
}

interface OpenAiCompatibleMessage {
  role: string;
  content: string;
}

interface OpenAiCompatibleRequest {
  model: string;
  temperature: number;
  messages: OpenAiCompatibleMessage[];
}

interface AnthropicCompatibleContentBlock {
  type: string;
  text: string;
}

interface AnthropicCompatibleMessage {
  role: string;
  content: AnthropicCompatibleContentBlock[];
}

interface AnthropicCompatibleRequest {
  model: string;
  system: string;
  max_tokens: number;
  temperature: number;
  messages: AnthropicCompatibleMessage[];
}

export class LlmPolishService {
  private readonly httpClient: RemoteHttpClient = new RemoteHttpClient();

  async polishText(config: OffhandLlmPolishConfig, request: LlmPolishRequest): Promise<LlmPolishResult> {
    let normalized = request.text.trim();
    if (normalized.length === 0) {
      return {
        text: '',
        source: 'local_fallback',
        provider: '本地润色'
      };
    }
    if (config.endpoint.length > 0 && config.apiModel.length > 0) {
      try {
        let remoteText = await this.requestRemotePolish(config, request);
        if (remoteText.length > 0) {
          return {
            text: remoteText,
            source: 'remote_llm',
            provider: buildProviderLabel(config)
          };
        }
      } catch (_) {
      }
    }
    if (config.fallbackToLocalRewrite) {
      return {
        text: locallyPolishText(normalized),
        source: 'local_fallback',
        provider: '本地润色'
      };
    }
    return {
      text: normalized,
      source: 'local_fallback',
      provider: '原文'
    };
  }

  private async requestRemotePolish(config: OffhandLlmPolishConfig, request: LlmPolishRequest): Promise<string> {
    if (config.protocol === 'anthropic-compatible') {
      let response = await this.httpClient.postJson(
        resolveAnthropicCompatibleEndpoint(config.endpoint),
        buildAnthropicCompatiblePayload(config, request),
        {
          timeoutMs: config.requestTimeoutMs,
          headers: createAnthropicCompatibleHeaders(config.apiKey)
        }
      );
      return extractAnthropicCompatibleText(response);
    }
    let response = await this.httpClient.postJson(
      resolveOpenAiCompatibleEndpoint(config.endpoint),
      buildOpenAiCompatiblePayload(config, request),
      {
        timeoutMs: config.requestTimeoutMs,
        headers: createOpenAiCompatibleHeaders(config.apiKey)
      }
    );
    return extractOpenAiCompatibleText(response);
  }
}

function buildOpenAiCompatiblePayload(config: OffhandLlmPolishConfig, request: LlmPolishRequest): OpenAiCompatibleRequest {
  let systemPrompt = buildSystemPrompt(request.style);
  let userPrompt = buildUserPrompt(request);
  return {
    model: config.apiModel,
    temperature: 0.2,
    messages: [
      {
        role: 'system',
        content: systemPrompt
      },
      {
        role: 'user',
        content: userPrompt
      }
    ]
  };
}

function buildAnthropicCompatiblePayload(config: OffhandLlmPolishConfig, request: LlmPolishRequest): AnthropicCompatibleRequest {
  return {
    model: config.apiModel,
    system: buildSystemPrompt(request.style),
    max_tokens: 1024,
    temperature: 0.2,
    messages: [
      {
        role: 'user',
        content: [
          {
            type: 'text',
            text: buildUserPrompt(request)
          }
        ]
      }
    ]
  };
}

function buildSystemPrompt(style: string): string {
  let normalizedStyle = normalizeStyleLabel(style);
  return [
    '你是输入法里的文本润色助手。',
    '请在不改变事实、数字、时间、专有名词和原意的前提下润色文本。',
    '优先去掉口头语、重复词和明显语病，让表达更自然、更清晰。',
    `当前风格：${normalizedStyle}。`,
    '如果原文已经足够好，只做最小修改。',
    '只返回润色后的最终文本，不要解释。'
  ].join('\n');
}

function buildUserPrompt(request: LlmPolishRequest): string {
  return [
    `locale=${request.locale}`,
    `subtypeId=${request.subtypeId}`,
    `style=${normalizeStyleLabel(request.style)}`,
    'text:',
    request.text.trim()
  ].join('\n');
}

function normalizeStyleLabel(style: string): string {
  let normalized = style.trim().toLowerCase();
  if (normalized === 'formal') {
    return 'formal';
  }
  if (normalized === 'clear') {
    return 'clear';
  }
  if (normalized === 'friendly') {
    return 'friendly';
  }
  if (normalized === 'light') {
    return 'light';
  }
  return 'clean_conversational';
}

function resolveOpenAiCompatibleEndpoint(endpoint: string): string {
  return appendEndpointPath(endpoint, '/chat/completions');
}

function resolveAnthropicCompatibleEndpoint(endpoint: string): string {
  return appendEndpointPath(endpoint, '/messages');
}

function appendEndpointPath(endpoint: string, suffix: string): string {
  let normalized = endpoint.trim();
  if (normalized.length === 0) {
    return '';
  }
  if (normalized.endsWith(suffix)) {
    return normalized;
  }
  if (normalized.endsWith('/')) {
    return `${normalized}${suffix.substring(1)}`;
  }
  return `${normalized}${suffix}`;
}

function createOpenAiCompatibleHeaders(apiKey?: string): Record<string, string> | undefined {
  if (!apiKey || apiKey.length === 0) {
    return undefined;
  }
  return {
    'Authorization': `Bearer ${apiKey}`
  };
}

function createAnthropicCompatibleHeaders(apiKey?: string): Record<string, string> {
  let headers: Record<string, string> = {
    'anthropic-version': '2023-06-01'
  };
  if (apiKey && apiKey.length > 0) {
    headers['x-api-key'] = apiKey;
  }
  return headers;
}

function extractOpenAiCompatibleText(response: Object): string {
  let choices = readObjectArrayValue(response, 'choices');
  if (choices.length > 0) {
    let firstChoice = choices[0];
    let message = readObjectValue(firstChoice, 'message');
    if (message) {
      let content = extractContentValue(message);
      if (content.length > 0) {
        return content;
      }
    }
    let directText = readStringValue(firstChoice, 'text');
    if (directText.length > 0) {
      return directText;
    }
  }
  return extractLegacyRemoteText(response);
}

function extractAnthropicCompatibleText(response: Object): string {
  let content = extractContentValue(response);
  if (content.length > 0) {
    return content;
  }
  return extractLegacyRemoteText(response);
}

function extractContentValue(source: Object): string {
  let directText = readStringValue(source, 'content');
  if (directText.length > 0) {
    return directText;
  }
  let blocks = readObjectArrayValue(source, 'content');
  let texts: string[] = [];
  for (let index = 0; index < blocks.length; index++) {
    let block = blocks[index];
    let text = readStringValue(block, 'text');
    if (text.length > 0) {
      texts.push(text);
    }
  }
  return texts.join('\n').trim();
}

function extractLegacyRemoteText(response: Object): string {
  let text = readStringValue(response, 'text');
  if (text.length > 0) {
    return text;
  }
  let result = readStringValue(response, 'result');
  if (result.length > 0) {
    return result;
  }
  let output = readStringValue(response, 'output');
  if (output.length > 0) {
    return output;
  }
  let outputText = readStringValue(response, 'output_text');
  if (outputText.length > 0) {
    return outputText;
  }
  return '';
}

function readStringValue(source: Object, key: string): string {
  let record = source as Record<string, Object | string | number | boolean | undefined>;
  let value = record[key];
  return typeof value === 'string' ? value.trim() : '';
}

function readObjectValue(source: Object, key: string): Object | undefined {
  let record = source as Record<string, Object | string | number | boolean | undefined>;
  let value = record[key];
  if (typeof value === 'object' && value !== null && !Array.isArray(value)) {
    return value as Object;
  }
  return undefined;
}

function readObjectArrayValue(source: Object, key: string): Object[] {
  let record = source as Record<string, Object | string | number | boolean | undefined>;
  let value = record[key];
  if (!Array.isArray(value)) {
    return [];
  }
  let items = value as Object[];
  let objects: Object[] = [];
  for (let index = 0; index < items.length; index++) {
    let item: Object = items[index];
    if (typeof item === 'object' && item !== null) {
      objects.push(item as Object);
    }
  }
  return objects;
}

function buildProviderLabel(config: OffhandLlmPolishConfig): string {
  if (config.providerName.length > 0 && config.modelDisplayName.length > 0) {
    return `${config.providerName} / ${config.modelDisplayName}`;
  }
  if (config.modelDisplayName.length > 0) {
    return config.modelDisplayName;
  }
  if (config.providerName.length > 0) {
    return config.providerName;
  }
  return '远端模型';
}

function locallyPolishText(text: string): string {
  let polished = text
    .replace(/[ \t]+/g, ' ')
    .replace(/\s+([,.!?])/g, '$1')
    .replace(/(^|[，。！？\s])(?:嗯|呃|啊|呀|诶)(?=[，。！？\s]|$)/g, '$1')
    .replace(/(^|[，。！？\s])(?:就是|然后|那个)(?=[，。！？\s]|$)/g, '$1')
    .replace(/\s+/g, ' ')
    .replace(/，{2,}/g, '，')
    .trim();
  if (polished.length === 0) {
    return '';
  }
  let hasChinese = /[\u4e00-\u9fa5]/.test(polished);
  let endsWithPunctuation = /[。！？.!?]$/.test(polished);
  if (hasChinese && !endsWithPunctuation) {
    polished = `${polished}。`;
  } else if (!hasChinese && !endsWithPunctuation) {
    polished = `${capitalize(polished)}.`;
  } else if (!hasChinese) {
    polished = capitalize(polished);
  }
  return polished;
}

function capitalize(text: string): string {
  if (text.length === 0) {
    return text;
  }
  return text[0].toUpperCase() + text.substring(1);
}
