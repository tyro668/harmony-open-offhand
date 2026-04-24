import { RemoteHttpClient } from '../network/RemoteHttpClient';
import { OffhandLlmPolishConfig } from '../common/ImeTypes';
import { hilog } from '@kit.PerformanceAnalysisKit';

const DOMAIN = 0xFF10;
const TAG = 'LlmPolishService';

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

export interface LlmStreamCallbacks {
  onDelta: (delta: string, accumulated: string) => void;
}

interface OpenAiCompatibleMessage {
  role: string;
  content: string;
}

interface OpenAiCompatibleRequest {
  model: string;
  temperature: number;
  messages: OpenAiCompatibleMessage[];
  stream?: boolean;
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
  stream?: boolean;
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
    let hasApiKey = config.apiKey !== undefined && config.apiKey.length > 0;
    hilog.info(DOMAIN, TAG,
      'polishText start: endpoint=%{public}s apiModel=%{public}s protocol=%{public}s hasApiKey=%{public}s textLen=%{public}d',
      config.endpoint, config.apiModel, config.protocol, String(hasApiKey), normalized.length);
    if (config.endpoint.length > 0 && config.apiModel.length > 0) {
      try {
        let remoteText = await this.requestRemotePolish(config, request);
        hilog.info(DOMAIN, TAG, 'polishText remote ok: textLen=%{public}d', remoteText.length);
        if (remoteText.length > 0) {
          return {
            text: remoteText,
            source: 'remote_llm',
            provider: buildProviderLabel(config)
          };
        }
      } catch (error) {
        hilog.warn(DOMAIN, TAG, 'polishText remote failed: %{public}s',
          (error as Error).message ?? String(error));
      }
    } else {
      hilog.warn(DOMAIN, TAG, 'polishText skipped remote call: endpoint or apiModel missing');
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
          headers: createAnthropicCompatibleHeaders(config.apiKey, config.endpoint)
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

  // Streams a polish request and forwards incremental text deltas through
  // `callbacks.onDelta`. Resolves with the final LlmPolishResult (full
  // polished text) after the server's SSE stream ends. Falls back to the
  // non-streaming `polishText` path if the endpoint / API key is not
  // configured, if streaming fails, or if the server emits no text deltas
  // (so the caller always receives a usable final result).
  async streamPolishText(config: OffhandLlmPolishConfig, request: LlmPolishRequest,
    callbacks: LlmStreamCallbacks): Promise<LlmPolishResult> {
    let normalized = request.text.trim();
    if (normalized.length === 0) {
      return {
        text: '',
        source: 'local_fallback',
        provider: '本地润色'
      };
    }
    let canStream = config.endpoint.length > 0 && config.apiModel.length > 0
      && (config.apiKey !== undefined && config.apiKey.length > 0);
    hilog.info(DOMAIN, TAG,
      'streamPolishText start: canStream=%{public}s endpoint=%{public}s apiModel=%{public}s protocol=%{public}s hasApiKey=%{public}s textLen=%{public}d',
      String(canStream), config.endpoint, config.apiModel, config.protocol,
      String(config.apiKey !== undefined && config.apiKey.length > 0), normalized.length);
    if (canStream) {
      try {
        let accumulated = '';
        let lineCount = 0;
        let onLine = (line: string): void => {
          lineCount += 1;
          let delta = parseStreamLineDelta(line, config.protocol);
          if (delta.length === 0) {
            return;
          }
          accumulated += delta;
          callbacks.onDelta(delta, accumulated);
        };
        if (config.protocol === 'anthropic-compatible') {
          await this.httpClient.postJsonStream(
            resolveAnthropicCompatibleEndpoint(config.endpoint),
            buildAnthropicCompatiblePayload(config, request, true),
            {
              timeoutMs: config.requestTimeoutMs,
              headers: createAnthropicCompatibleStreamHeaders(config.apiKey, config.endpoint)
            },
            { onLine: onLine }
          );
        } else {
          await this.httpClient.postJsonStream(
            resolveOpenAiCompatibleEndpoint(config.endpoint),
            buildOpenAiCompatiblePayload(config, request, true),
            {
              timeoutMs: config.requestTimeoutMs,
              headers: createOpenAiCompatibleHeaders(config.apiKey)
            },
            { onLine: onLine }
          );
        }
        hilog.info(DOMAIN, TAG,
          'streamPolishText stream done: lines=%{public}d accumulatedLen=%{public}d',
          lineCount, accumulated.length);
        if (accumulated.length > 0) {
          return {
            text: accumulated,
            source: 'remote_llm',
            provider: buildProviderLabel(config)
          };
        }
      } catch (error) {
        hilog.warn(DOMAIN, TAG, 'streamPolishText stream failed: %{public}s',
          (error as Error).message ?? String(error));
        // fall through to non-streaming polish below
      }
    }
    return this.polishText(config, request);
  }
}

// Parses one SSE line into a text delta. Handles OpenAI-compatible chat
// completions chunks and Anthropic content_block_delta events. Lines that
// carry no text delta (role-only, keep-alive, [DONE], etc.) return ''.
function parseStreamLineDelta(line: string, protocol: string): string {
  let trimmed = line.trim();
  if (trimmed.length === 0 || trimmed.startsWith(':') || trimmed.startsWith('event:')) {
    return '';
  }
  let payload = trimmed.startsWith('data:') ? trimmed.substring(5).trim() : trimmed;
  if (payload.length === 0 || payload === '[DONE]') {
    return '';
  }
  let parsed: Object;
  try {
    parsed = JSON.parse(payload) as Object;
  } catch (_) {
    return '';
  }
  if (protocol === 'anthropic-compatible') {
    let type = readStringValue(parsed, 'type');
    if (type === 'content_block_delta' || type === 'message_delta' || type.length === 0) {
      let delta = readObjectValue(parsed, 'delta');
      if (delta) {
        let text = readStringValue(delta, 'text');
        if (text.length > 0) {
          return text;
        }
      }
    }
    return '';
  }
  // OpenAI-compatible
  let choices = readObjectArrayValue(parsed, 'choices');
  if (choices.length === 0) {
    return '';
  }
  let firstChoice = choices[0];
  let delta = readObjectValue(firstChoice, 'delta');
  if (delta) {
    let content = readStringValue(delta, 'content');
    if (content.length > 0) {
      return content;
    }
  }
  let message = readObjectValue(firstChoice, 'message');
  if (message) {
    let content = readStringValue(message, 'content');
    if (content.length > 0) {
      return content;
    }
  }
  return '';
}

function buildOpenAiCompatiblePayload(config: OffhandLlmPolishConfig, request: LlmPolishRequest,
  stream: boolean = false): OpenAiCompatibleRequest {
  let systemPrompt = buildSystemPrompt(request.style);
  let userPrompt = buildUserPrompt(request);
  let payload: OpenAiCompatibleRequest = {
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
  if (stream) {
    payload.stream = true;
  }
  return payload;
}

function buildAnthropicCompatiblePayload(config: OffhandLlmPolishConfig, request: LlmPolishRequest,
  stream: boolean = false): AnthropicCompatibleRequest {
  let payload: AnthropicCompatibleRequest = {
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
  if (stream) {
    payload.stream = true;
  }
  return payload;
}

function buildSystemPrompt(style: string): string {
  // Keep in sync with design/config/default-prompt.md.
  let normalizedStyle = normalizeStyleLabel(style);
  return [
    '# 文本无损优化提示词',
    '',
    '## 角色设定',
    '你是一个克制、可靠的文本编辑助手，负责清理口语化文本并提升可读性。',
    '',
    '## 核心任务',
    '对提供的**已成文文本**进行“无损润色”。去除口语杂质与冗余，但严格保留原意、关键信息和语气。',
    '',
    '## 处理规则',
    '1. **清理口语碎词：** 删除无意义语气词（如“呃、那个、然后、就是说、啊、嗯”）。',
    '2. **消除重复：** 合并重复词句，保留一次即可。',
    '3. **微调语法：** 修正明显病句、搭配错误与语序问题，使表达通顺。',
    '4. **严格保真：**',
    '   - 禁止新增原文没有的信息、观点或结论。',
    '   - 禁止过度改写成公文腔或 AI 腔。',
    '   - 保留专有名词、术语、数字、单位、时间与人名。',
    '5. **标点与分段：** 补全标点并按语义合理分段。',
    '6. **语言规范：** 统一使用简体中文输出。',
    '',
    `## 当前风格\n${normalizedStyle}`,
    '',
    '## 输出格式',
    '仅输出优化后的正文，不要输出解释、标题、前后缀或额外说明。'
  ].join('\n');
}

function buildUserPrompt(request: LlmPolishRequest): string {
  return request.text.trim();
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

function createAnthropicCompatibleHeaders(apiKey?: string, endpoint?: string): Record<string, string> {
  let headers: Record<string, string> = {
    'anthropic-version': '2023-06-01'
  };
  if (apiKey && apiKey.length > 0) {
    // Official Anthropic API authenticates with `x-api-key`. Anthropic-
    // compatible gateways that impersonate Claude (e.g. Kimi Code at
    // api.kimi.com) use the Claude Code / ANTHROPIC_AUTH_TOKEN convention,
    // which is `Authorization: Bearer <token>`. Sending x-api-key to these
    // gateways often triggers a spurious 401 because the server treats the
    // request as an official Anthropic call and rejects a non-Anthropic
    // key. We therefore pick the header based on the endpoint host.
    let host = (endpoint ?? '').toLowerCase();
    let isOfficialAnthropic = host.indexOf('api.anthropic.com') >= 0;
    if (isOfficialAnthropic) {
      headers['x-api-key'] = apiKey;
    } else {
      headers['Authorization'] = `Bearer ${apiKey}`;
    }
  }
  return headers;
}

function createAnthropicCompatibleStreamHeaders(apiKey?: string, endpoint?: string): Record<string, string> {
  let headers = createAnthropicCompatibleHeaders(apiKey, endpoint);
  headers['accept'] = 'text/event-stream';
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
