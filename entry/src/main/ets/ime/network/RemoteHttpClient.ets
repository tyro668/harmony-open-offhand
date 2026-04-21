import http from '@ohos.net.http';
import { util } from '@kit.ArkTS';

export interface JsonRequestOptions {
  timeoutMs: number;
  headers?: Record<string, string>;
}

export class RemoteHttpClient {
  private readonly decoder: util.TextDecoder = util.TextDecoder.create('utf-8');

  async postJson(url: string, payload: Object, options: JsonRequestOptions): Promise<Object> {
    let request = http.createHttp();
    try {
      let headers = createRequestHeaders(options.headers);
      let requestOptions: http.HttpRequestOptions = {
        method: http.RequestMethod.POST,
        expectDataType: http.HttpDataType.STRING,
        connectTimeout: options.timeoutMs,
        readTimeout: options.timeoutMs,
        header: headers,
        extraData: JSON.stringify(payload)
      };
      let response = await request.request(url, requestOptions);
      let responseCode = Number(response.responseCode ?? 0);
      if (responseCode < 200 || responseCode >= 300) {
        throw new Error(`HTTP ${responseCode}`);
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
