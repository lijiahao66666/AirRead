import type { ProviderProfile } from './providerProfile';
import {
  assertSuccessfulResponse,
  connectionError,
  ProviderRequestError,
  fetchWithTimeout,
  type TranslationEngine,
  type TranslationRequest,
} from './translationTypes';

const encoder = new TextEncoder();
const HOST = 'tmt.tencentcloudapi.com';
const SERVICE = 'tmt';

const hex = (bytes: ArrayBuffer): string => Array.from(new Uint8Array(bytes))
  .map((byte) => byte.toString(16).padStart(2, '0'))
  .join('');

const sha256 = async (value: string): Promise<string> => hex(await crypto.subtle.digest('SHA-256', encoder.encode(value)));

const hmac = async (key: BufferSource, value: string): Promise<ArrayBuffer> => {
  const cryptoKey = await crypto.subtle.importKey('raw', key, { name: 'HMAC', hash: 'SHA-256' }, false, ['sign']);
  return crypto.subtle.sign('HMAC', cryptoKey, encoder.encode(value));
};

const languageForTencent = (language: string): string => {
  const normalized = language.toLowerCase();
  if (normalized === 'zh-cn' || normalized === 'zh-hans') return 'zh';
  if (normalized === 'zh-tw' || normalized === 'zh-hant') return 'zh-TW';
  return language.split('-')[0];
};

export class TencentTmtEngine implements TranslationEngine {
  readonly cacheIdentity: string;

  constructor(private readonly profile: ProviderProfile) {
    this.cacheIdentity = [profile.kind, profile.id, '', '', profile.region ?? ''].join('|');
  }

  async translate(input: TranslationRequest): Promise<string> {
    const separator = this.profile.apiKey!.indexOf(':');
    const secretId = this.profile.apiKey!.slice(0, separator);
    const secretKey = this.profile.apiKey!.slice(separator + 1);
    const timestamp = Math.floor(Date.now() / 1000);
    const date = new Date(timestamp * 1000).toISOString().slice(0, 10);
    const body = JSON.stringify({
      SourceText: input.text,
      Source: input.sourceLanguage ? languageForTencent(input.sourceLanguage) : 'auto',
      Target: languageForTencent(input.targetLanguage),
      ProjectId: 0,
    });
    const canonicalHeaders = `content-type:application/json; charset=utf-8\nhost:${HOST}\n`;
    const signedHeaders = 'content-type;host';
    const credentialScope = `${date}/${SERVICE}/tc3_request`;
    let authorization: string;
    try {
      const canonicalRequest = `POST\n/\n\n${canonicalHeaders}\n${signedHeaders}\n${await sha256(body)}`;
      const stringToSign = `TC3-HMAC-SHA256\n${timestamp}\n${credentialScope}\n${await sha256(canonicalRequest)}`;
      const secretDate = await hmac(encoder.encode(`TC3${secretKey}`), date);
      const secretService = await hmac(secretDate, SERVICE);
      const secretSigning = await hmac(secretService, 'tc3_request');
      const signature = hex(await hmac(secretSigning, stringToSign));
      authorization = `TC3-HMAC-SHA256 Credential=${secretId}/${credentialScope}, SignedHeaders=${signedHeaders}, Signature=${signature}`;
    } catch {
      throw new ProviderRequestError(this.profile.name);
    }

    let response: Response;
    try {
      response = await fetchWithTimeout(`https://${HOST}`, {
        method: 'POST',
        headers: {
          Authorization: authorization,
          'Content-Type': 'application/json; charset=utf-8',
          'X-TC-Action': 'TextTranslate',
          'X-TC-Region': this.profile.region!,
          'X-TC-Timestamp': String(timestamp),
          'X-TC-Version': '2018-03-21',
        },
        body,
      });
    } catch {
      throw connectionError(this.profile.name);
    }
    assertSuccessfulResponse(response, this.profile.name);
    try {
      const payload: unknown = await response.json();
      const translated = (payload as { Response?: { TargetText?: unknown; Error?: unknown } }).Response?.TargetText;
      if (typeof translated === 'string' && translated.trim()) return translated.trim();
    } catch {
      // Normalize malformed provider responses below.
    }
    throw new ProviderRequestError(this.profile.name);
  }
}
