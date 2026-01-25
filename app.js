'use strict';

const http = require('http');
const https = require('https');
const crypto = require('crypto');

/*
 * AirRead Unified SCF Function
 * 
 * Capabilities:
 * 1. Proxy Tencent Cloud API requests (Hunyuan, TTS, TMT) to bypass browser CORS and protect secret keys.
 * 2. Handle License Redemption (Anti-replay check using COS).
 * 
 * Environment Variables Required:
 * - TENCENT_SECRET_ID / TENCENT_SECRET_KEY: For signing API requests.
 * - TENCENTCLOUD_SECRETID / TENCENTCLOUD_SECRETKEY / TENCENTCLOUD_SESSIONTOKEN: (Auto-injected by SCF) For accessing COS.
 * - BUCKET_NAME: (Optional, for License) e.g., "license-keys-1250000000".
 * - REGION: (Optional, for License) e.g., "ap-guangzhou".
 */

// --- Helper: SHA256 & HMAC ---
function sha256Hex(s) {
  return crypto.createHash('sha256').update(s, 'utf8').digest('hex');
}

function hmacSha256(key, msg, encoding) {
  return crypto.createHmac('sha256', key).update(msg, 'utf8').digest(encoding);
}

function sha1Hex(s) {
  return crypto.createHash('sha1').update(s, 'utf8').digest('hex');
}

function hmacSha1Hex(key, msg) {
  return crypto.createHmac('sha1', key).update(msg, 'utf8').digest('hex');
}

function uriEncode(s) {
  return encodeURIComponent(s)
    .replace(/[!'()*]/g, (c) => `%${c.charCodeAt(0).toString(16).toUpperCase()}`);
}

function formatDateUTC(tsSeconds) {
  const d = new Date(tsSeconds * 1000);
  const y = d.getUTCFullYear();
  const m = String(d.getUTCMonth() + 1).padStart(2, '0');
  const day = String(d.getUTCDate()).padStart(2, '0');
  return `${y}-${m}-${day}`;
}

// --- Helper: Tencent Cloud v3 Signature ---
function buildTc3Auth({
  secretId,
  secretKey,
  service,
  host,
  action,
  version,
  region,
  timestampSeconds,
  payloadJson,
}) {
  const algorithm = 'TC3-HMAC-SHA256';
  const date = formatDateUTC(timestampSeconds);

  const canonicalUri = '/';
  const canonicalQueryString = '';
  const canonicalHeaders = `content-type:application/json; charset=utf-8\nhost:${host}\n`;
  const signedHeaders = 'content-type;host';
  const hashedRequestPayload = sha256Hex(payloadJson);

  const canonicalRequest = [
    'POST',
    canonicalUri,
    canonicalQueryString,
    canonicalHeaders,
    signedHeaders,
    hashedRequestPayload,
  ].join('\n');

  const credentialScope = `${date}/${service}/tc3_request`;
  const stringToSign = [
    algorithm,
    String(timestampSeconds),
    credentialScope,
    sha256Hex(canonicalRequest),
  ].join('\n');

  const secretDate = hmacSha256(`TC3${secretKey}`, date);
  const secretService = hmacSha256(secretDate, service);
  const secretSigning = hmacSha256(secretService, 'tc3_request');
  const signature = hmacSha256(secretSigning, stringToSign, 'hex');

  const authorization =
    `${algorithm} ` +
    `Credential=${secretId}/${credentialScope}, ` +
    `SignedHeaders=${signedHeaders}, ` +
    `Signature=${signature}`;

  const headers = {
    'Content-Type': 'application/json; charset=utf-8',
    Host: host,
    'X-TC-Action': action,
    'X-TC-Version': version,
    'X-TC-Timestamp': String(timestampSeconds),
    Authorization: authorization,
  };
  if (region && String(region).trim()) headers['X-TC-Region'] = String(region).trim();

  return headers;
}

function buildCosAuthorization({
  secretId,
  secretKey,
  method,
  path,
  headers,
  query,
  startTime,
  endTime,
}) {
  const signTime = `${startTime};${endTime}`;
  const keyTime = signTime;
  const signKey = hmacSha1Hex(secretKey, keyTime);

  const headerKeys = Object.keys(headers || {})
    .map((k) => k.toLowerCase())
    .sort();
  const headerList = headerKeys.join(';');
  const headerString = headerKeys
    .map((k) => `${k}=${uriEncode(String(headers[k] ?? '').trim())}`)
    .join('&');

  const queryKeys = Object.keys(query || {})
    .map((k) => k.toLowerCase())
    .sort();
  const queryList = queryKeys.join(';');
  const queryString = queryKeys
    .map((k) => `${k}=${uriEncode(String(query[k] ?? '').trim())}`)
    .join('&');

  const formatString = [
    String(method || 'get').toLowerCase(),
    path,
    queryString,
    headerString,
    '',
  ].join('\n');
  const stringToSign = [
    'sha1',
    keyTime,
    sha1Hex(formatString),
    '',
  ].join('\n');
  const signature = hmacSha1Hex(signKey, stringToSign);
  return `q-sign-algorithm=sha1&q-ak=${secretId}&q-sign-time=${signTime}&q-key-time=${keyTime}&q-header-list=${headerList}&q-url-param-list=${queryList}&q-signature=${signature}`;
}

function buildCosPath(key) {
  const encoded = String(key || '').split('/').map((seg) => encodeURIComponent(seg)).join('/');
  return `/${encoded}`;
}

function cosRequest({
  method,
  bucket,
  region,
  key,
  headers,
  query,
  body,
  credentials,
}) {
  const cred = credentials || {};
  const secretId =
    cred.secretId ||
    cred.TmpSecretId ||
    process.env.TENCENT_SECRET_ID ||
    process.env.TENCENTCLOUD_SECRETID ||
    '';
  const secretKey =
    cred.secretKey ||
    cred.TmpSecretKey ||
    process.env.TENCENT_SECRET_KEY ||
    process.env.TENCENTCLOUD_SECRETKEY ||
    '';
  const token =
    cred.sessionToken ||
    cred.SecurityToken ||
    process.env.TENCENTCLOUD_SESSIONTOKEN ||
    '';
  if (!String(secretId).trim() || !String(secretKey).trim()) {
    return Promise.reject(new Error('Missing COS credentials'));
  }

  const host = `${bucket}.cos.${region}.myqcloud.com`;
  const path = buildCosPath(key);
  const finalHeaders = Object.assign({}, headers || {});
  finalHeaders.host = host;
  if (String(token).trim()) {
    finalHeaders['x-cos-security-token'] = token;
  }
  const now = Math.floor(Date.now() / 1000);
  const authorization = buildCosAuthorization({
    secretId: String(secretId).trim(),
    secretKey: String(secretKey).trim(),
    method,
    path,
    headers: finalHeaders,
    query: query || {},
    startTime: now - 60,
    endTime: now + 600,
  });
  finalHeaders.Authorization = authorization;

  const options = {
    protocol: 'https:',
    hostname: host,
    method,
    path,
    headers: finalHeaders,
  };

  return new Promise((resolve, reject) => {
    const req = https.request(options, (resp) => {
      const chunks = [];
      resp.on('data', (c) => chunks.push(c));
      resp.on('end', () => {
        resolve({
          statusCode: resp.statusCode || 0,
          headers: resp.headers || {},
          body: Buffer.concat(chunks),
        });
      });
    });
    req.on('error', reject);
    if (body && body.length) {
      req.write(body);
    }
    req.end();
  });
}

async function cosHeadObject({ bucket, region, key, credentials }) {
  const resp = await cosRequest({
    method: 'HEAD',
    bucket,
    region,
    key,
    headers: {},
    query: {},
    credentials,
  });
  return resp.statusCode || 0;
}

async function cosPutObject({ bucket, region, key, headers, credentials }) {
  const body = Buffer.from('');
  const resp = await cosRequest({
    method: 'PUT',
    bucket,
    region,
    key,
    headers: Object.assign(
      {
        'content-length': String(body.length),
      },
      headers || {}
    ),
    query: {},
    body,
    credentials,
  });
  return resp.statusCode || 0;
}

// --- Helper: HTTP Utils ---
function readJsonBody(req) {
  return new Promise((resolve, reject) => {
    let data = '';
    req.on('data', (chunk) => {
      data += chunk.toString('utf8');
      if (data.length > 2 * 1024 * 1024) {
        reject(new Error('Body too large'));
        req.destroy();
      }
    });
    req.on('end', () => {
      if (!data.trim()) return resolve({});
      try {
        resolve(JSON.parse(data));
      } catch (e) {
        reject(e);
      }
    });
    req.on('error', reject);
  });
}

function sendJson(res, statusCode, obj) {
  const body = JSON.stringify(obj);
  res.statusCode = statusCode;
  res.setHeader('Content-Type', 'application/json; charset=utf-8');
  res.setHeader('Access-Control-Allow-Origin', '*'); // CORS for all responses
  res.setHeader('Content-Length', Buffer.byteLength(body));
  res.end(body);
}

// --- Logic: API Proxy (Existing) ---
function isAllowedHost(host) {
  const allow = new Set([
    'hunyuan.tencentcloudapi.com',
    'tmt.tencentcloudapi.com',
    'tts.tencentcloudapi.com',
  ]);
  return allow.has(String(host || '').toLowerCase());
}

function isAllowedAction(action) {
  const allow = new Set(['ChatCompletions', 'ChatTranslations', 'TextToVoice', 'TextTranslate']);
  return allow.has(String(action || ''));
}

async function handleApiProxy(req, res, body) {
  const {
    host,
    service,
    action,
    version,
    region,
    payload,
    stream,
    timestamp,
  } = body || {};

  if (!host || !service || !action || !version || !payload) {
    return sendJson(res, 400, { error: 'BadRequest', message: 'Missing required fields' });
  }

  if (!isAllowedHost(host) || !isAllowedAction(action)) {
    return sendJson(res, 403, { error: 'Forbidden', message: 'Host or action not allowed' });
  }

  const secretId = process.env.TENCENT_SECRET_ID || '';
  const secretKey = process.env.TENCENT_SECRET_KEY || '';
  if (!secretId.trim() || !secretKey.trim()) {
    return sendJson(res, 500, { error: 'MissingCredentials', message: 'Set TENCENT_SECRET_ID / TENCENT_SECRET_KEY' });
  }

  const ts = Number.isFinite(Number(timestamp)) ? Number(timestamp) : Math.floor(Date.now() / 1000);
  const upstreamPayloadJson = JSON.stringify(payload);

  const headers = buildTc3Auth({
    secretId,
    secretKey,
    service,
    host,
    action,
    version,
    region,
    timestampSeconds: ts,
    payloadJson: upstreamPayloadJson,
  });

  const useStream = Boolean(stream);
  if (useStream) {
    headers.Accept = 'text/event-stream';
  }

  const options = {
    protocol: 'https:',
    hostname: String(host),
    method: 'POST',
    path: '/',
    headers,
  };

  const upstreamReq = https.request(options, (upstreamRes) => {
    res.statusCode = upstreamRes.statusCode || 200;
    res.setHeader('Access-Control-Allow-Origin', '*');

    const contentType = (upstreamRes.headers['content-type'] || '').toString();

    if (useStream) {
      res.setHeader('Content-Type', 'text/event-stream; charset=utf-8');
      res.setHeader('Cache-Control', 'no-cache');
      res.setHeader('Connection', 'keep-alive');

      upstreamRes.on('data', (chunk) => {
        res.write(chunk);
      });
      upstreamRes.on('end', () => res.end());
      upstreamRes.on('error', () => res.end());

      req.on('close', () => {
        try { upstreamReq.destroy(); } catch (_) {}
      });
      return;
    }

    let buf = [];
    upstreamRes.on('data', (c) => buf.push(c));
    upstreamRes.on('end', () => {
      const raw = Buffer.concat(buf).toString('utf8');
      if ((upstreamRes.statusCode || 500) < 200 || (upstreamRes.statusCode || 500) >= 300) {
        sendJson(res, upstreamRes.statusCode || 500, { error: 'UpstreamHttpError', status: upstreamRes.statusCode, body: raw });
        return;
      }
      try {
        const json = JSON.parse(raw);
        sendJson(res, 200, json);
      } catch (_) {
        sendJson(res, 200, { body: raw, contentType });
      }
    });
  });

  upstreamReq.on('error', (e) => {
    if (!res.headersSent) sendJson(res, 502, { error: 'BadGateway', message: String(e && e.message ? e.message : e) });
    else res.end();
  });

  upstreamReq.write(upstreamPayloadJson);
  upstreamReq.end();
}

// --- Logic: License Redemption (New) ---
async function handleLicenseRedeem(req, res, body) {
  const licenseCode = (body.license_code || '').trim();
  const deviceId = (body.device_id || '').trim();

  if (!licenseCode) {
    return sendJson(res, 400, { error: 'Missing license_code' });
  }

  const bucket = process.env.BUCKET_NAME;
  const region = process.env.REGION;
  const credentials = body.cos_credentials || body.cosCredentials || null;
  
  if (!bucket || !region) {
    return sendJson(res, 500, { error: 'Server Misconfiguration', message: 'BUCKET_NAME or REGION not set' });
  }

  // Calculate hash of the license code to use as the key in COS
  const codeHash = sha256Hex(licenseCode);
  const usedKeyPath = `used_keys/${codeHash}`;

  try {
    const headStatus = await cosHeadObject({
      bucket,
      region,
      key: usedKeyPath,
      credentials,
    });
    if (headStatus === 200) {
      sendJson(res, 409, { error: 'License key already used', code: 'ALREADY_USED', used: true });
      return;
    }
    if (headStatus !== 404) {
      throw new Error(`COS Head Error: ${headStatus}`);
    }

    const putStatus = await cosPutObject({
      bucket,
      region,
      key: usedKeyPath,
      headers: {
        'x-cos-meta-device-id': deviceId,
        'x-cos-meta-redeemed-at': new Date().toISOString(),
      },
      credentials,
    });
    if (putStatus < 200 || putStatus >= 300) {
      throw new Error(`COS Put Error: ${putStatus}`);
    }

    sendJson(res, 200, { message: 'License redeemed successfully', used: false });

  } catch (err) {
    sendJson(res, 500, { error: 'COS Error', message: String(err.message || err) });
  }
}

// --- Main Server ---
const server = http.createServer(async (req, res) => {
  // CORS Preflight
  if (req.method === 'OPTIONS') {
    res.statusCode = 204;
    res.setHeader('Access-Control-Allow-Origin', '*');
    res.setHeader('Access-Control-Allow-Headers', 'content-type,x-airread-token,accept');
    res.setHeader('Access-Control-Allow-Methods', 'POST, OPTIONS');
    res.end();
    return;
  }

  if (req.method !== 'POST') {
    sendJson(res, 405, { error: 'MethodNotAllowed' });
    return;
  }

  let body;
  try {
    body = await readJsonBody(req);
  } catch (e) {
    sendJson(res, 400, { error: 'InvalidJson', message: String(e && e.message ? e.message : e) });
    return;
  }

  // Route Dispatch based on payload content
  if (body.license_code) {
    // It's a license redemption request
    await handleLicenseRedeem(req, res, body);
  } else {
    // It's an API proxy request
    await handleApiProxy(req, res, body);
  }
});

const port = process.env.PORT ? Number(process.env.PORT) : 9000;
server.listen(port);
