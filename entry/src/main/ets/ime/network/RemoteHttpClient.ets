import http from '@ohos.net.http';
import { util } from '@kit.ArkTS';
import { BusinessError } from '@kit.BasicServicesKit';
import { hilog } from '@kit.PerformanceAnalysisKit';

const HTTP_LOG_DOMAIN: number = 0xFF10;
const HTTP_LOG_TAG: string = 'RemoteHttpClient';

function summarizeRequestHeaders(headers: Record<string, string>): string {
  let keys = Object.keys(headers);
  let parts: string[] = [];
  for (let index = 0; index < keys.length; index++) {
    let key = keys[index];
    let value = headers[key];
    let lower = key.toLowerCase();
    if (lower === 'authorization' || lower === 'x-api-key' || lower === 'anthropic-auth-token') {
      let tail = value.length > 6 ? value.substring(value.length - 4) : '****';
      parts.push(`${key}=<redacted len=${value.length} tail=${tail}>`);
    } else {
      parts.push(`${key}=${value}`);
    }
  }
  return parts.join('; ');
}

export interface JsonRequestOptions {
  timeoutMs: number;
  headers?: Record<string, string>;
}

export interface SseStreamCallbacks {
  onLine: (line: string) => void;
  onError?: (error: Error) => void;
}

export class RemoteHttpClient {
  private readonly decoder: util.TextDecoder = util.TextDecoder.create('utf-8');

  async postJson(url: string, payload: Object, options: JsonRequestOptions): Promise<Object> {
    let request = http.createHttp();
    try {
      let headers = createRequestHeaders(options.headers);
      hilog.info(HTTP_LOG_DOMAIN, HTTP_LOG_TAG,
        'postJson -> %{public}s headers=[%{public}s]', url, summarizeRequestHeaders(headers));
      let requestOptions: http.HttpRequestOptions = {
        method: http.RequestMethod.POST,
        expectDataType: http.HttpDataType.STRING,
        connectTimeout: Math.min(options.timeoutMs, 10000),
        readTimeout: options.timeoutMs,
        header: headers,
        extraData: JSON.stringify(payload)
      };
      let response = await request.request(url, requestOptions);
      let responseCode = Number(response.responseCode ?? 0);
      if (responseCode < 200 || responseCode >= 300) {
        let bodyPreview = this.normalizeResponseBody(response.result);
        if (bodyPreview.length > 512) {
          bodyPreview = bodyPreview.substring(0, 512) + '…';
        }
        throw new Error(`HTTP ${responseCode} body=${bodyPreview}`);
      }
      let raw = this.normalizeResponseBody(response.result);
      if (raw.length === 0) {
        return JSON.parse('{}') as Object;
      }
      return JSON.parse(raw) as Object;
    } finally {
      request.destroy();
    }
  }

  // Issues an SSE POST request and invokes `callbacks.onLine` for every
  // complete text line emitted by the server (trailing `\n` stripped, blank
  // lines suppressed). Callers parse the `data: ...` payload themselves.
  async postJsonStream(url: string, payload: Object, options: JsonRequestOptions,
    callbacks: SseStreamCallbacks): Promise<void> {
    let request = http.createHttp();
    let buffer = '';
    let settled = false;
    return new Promise<void>((resolve, reject) => {
      let finish = (error?: Error): void => {
        if (settled) {
          return;
        }
        settled = true;
        try {
          request.off('dataReceive');
          request.off('dataEnd');
          request.off('headersReceive');
        } catch (_) {
        }
        try {
          request.destroy();
        } catch (_) {
        }
        if (error) {
          if (callbacks.onError) {
            callbacks.onError(error);
          }
          reject(error);
        } else {
          resolve();
        }
      };

      request.on('headersReceive', (_header: Object): void => {
      });
      request.on('dataReceive', (chunk: ArrayBuffer): void => {
        try {
          let text = this.decoder.decodeToString(new Uint8Array(chunk));
          buffer += text;
          while (true) {
            let newlineIndex = buffer.indexOf('\n');
            if (newlineIndex < 0) {
              break;
            }
            let line = buffer.substring(0, newlineIndex);
            buffer = buffer.substring(newlineIndex + 1);
            if (line.endsWith('\r')) {
              line = line.substring(0, line.length - 1);
            }
            if (line.length > 0) {
              callbacks.onLine(line);
            }
          }
        } catch (error) {
          finish(error as Error);
        }
      });
      request.on('dataEnd', (): void => {
        if (buffer.length > 0) {
          let remaining = buffer.trim();
          if (remaining.length > 0) {
            try {
              callbacks.onLine(remaining);
            } catch (_) {
            }
          }
          buffer = '';
        }
        finish();
      });

      let streamOptions: http.HttpRequestOptions = {
        method: http.RequestMethod.POST,
        connectTimeout: Math.min(options.timeoutMs, 10000),
        readTimeout: options.timeoutMs,
        header: createStreamRequestHeaders(options.headers),
        extraData: JSON.stringify(payload)
      };
      hilog.info(HTTP_LOG_DOMAIN, HTTP_LOG_TAG,
        'postJsonStream -> %{public}s headers=[%{public}s]', url,
        summarizeRequestHeaders(streamOptions.header as Record<string, string>));
      request.requestInStream(url, streamOptions,
        (err: BusinessError, statusCode: number): void => {
          if (err) {
            finish(new Error(`stream error: ${err.message ?? String(err.code ?? 'unknown')}`));
            return;
          }
          if (statusCode < 200 || statusCode >= 300) {
            finish(new Error(`HTTP ${statusCode}`));
          }
          // Otherwise wait for dataEnd to resolve the promise.
        });
    });
  }

  private normalizeResponseBody(result: string | Object | ArrayBuffer): string {
    if (typeof result === 'string') {
      return result;
    }
    if (result instanceof ArrayBuffer) {
      return this.decoder.decodeToString(new Uint8Array(result));
    }
    return JSON.stringify(result);
  }
}

function createRequestHeaders(extraHeaders?: Record<string, string>): Record<string, string> {
  let headers: Record<string, string> = {
    'Content-Type': 'application/json',
    'Accept': 'application/json'
  };
  if (!extraHeaders) {
    return headers;
  }
  let keys = Object.keys(extraHeaders);
  for (let index = 0; index < keys.length; index++) {
    let key = keys[index];
    let value = extraHeaders[key];
    if (value !== undefined) {
      headers[key] = value;
    }
  }
  return headers;
}

function createStreamRequestHeaders(extraHeaders?: Record<string, string>): Record<string, string> {
  let headers: Record<string, string> = {
    'Content-Type': 'application/json',
    'Accept': 'text/event-stream'
  };
  if (!extraHeaders) {
    return headers;
  }
  let keys = Object.keys(extraHeaders);
  for (let index = 0; index < keys.length; index++) {
    let key = keys[index];
    let value = extraHeaders[key];
    if (value !== undefined) {
      headers[key] = value;
    }
  }
  return headers;
}
