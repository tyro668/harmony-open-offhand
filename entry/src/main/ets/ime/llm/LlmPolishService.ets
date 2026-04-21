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
}

interface RemotePolishPayload {
  text: string;
  locale: string;
  subtypeId: string;
  style: string;
}

export class LlmPolishService {
  private readonly httpClient: RemoteHttpClient = new RemoteHttpClient();

  async polishText(config: OffhandLlmPolishConfig, request: LlmPolishRequest): Promise<LlmPolishResult> {
    let normalized = request.text.trim();
    if (normalized.length === 0) {
      return {
        text: '',
        source: 'local_fallback'
      };
    }
    if (config.endpoint.length > 0) {
      try {
        let payload: RemotePolishPayload = {
          text: normalized,
          locale: request.locale,
          subtypeId: request.subtypeId,
          style: request.style
        };
        let response = await this.httpClient.postJson(config.endpoint, payload, {
          timeoutMs: config.requestTimeoutMs,
          headers: createAuthorizationHeaders(config.apiKey)
        });
        let remoteText = extractRemoteText(response);
        if (remoteText.length > 0) {
          return {
            text: remoteText,
            source: 'remote_llm'
          };
        }
      } catch (_) {
      }
    }
    if (config.fallbackToLocalRewrite) {
      return {
        text: locallyPolishText(normalized),
        source: 'local_fallback'
      };
    }
    return {
      text: normalized,
      source: 'local_fallback'
    };
  }
}

function createAuthorizationHeaders(apiKey?: string): Record<string, string> | undefined {
  if (!apiKey || apiKey.length === 0) {
    return undefined;
  }
  return {
    'Authorization': `Bearer ${apiKey}`
  };
}

function extractRemoteText(response: Object): string {
  let payload = response as Record<string, Object | string | number | boolean | undefined>;
  if (typeof payload.text === 'string') {
    return payload.text.trim();
  }
  if (typeof payload.result === 'string') {
    return payload.result.trim();
  }
  if (typeof payload.output === 'string') {
    return payload.output.trim();
  }
  return '';
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
