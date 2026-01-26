'use strict';

const http = require('http');
const https = require('https');
const crypto = require('crypto');

// --- Helper: Ed25519 & JWT ---
function getEd25519PublicKey(base64Key) {
  // Convert raw 32-byte key to SPKI format for Node.js crypto
  // OID: 1.3.101.112 (Ed25519)
  // Prefix: Sequence(42) { Sequence(5) { OID(3) }, BitString(33) { 0x00, ... } }
  // Hex: 30 2a 30 05 06 03 2b 65 70 03 21 00
  const prefix = Buffer.from('302a300506032b6570032100', 'hex');
  const rawKey = Buffer.from(base64Key, 'base64');
  if (rawKey.length !== 32) {
    throw new Error('Invalid Ed25519 public key length');
  }
  const der = Buffer.concat([prefix, rawKey]);
  return crypto.createPublicKey({
    key: der,
    format: 'der',
    type: 'spki',
  });
}

function verifyEd25519(data, signature, publicKey) {
  return crypto.verify(null, data, publicKey, signature);
}

function base64UrlEncode(str) {
  return Buffer.from(str)
    .toString('base64')
    .replace(/=/g, '')
    .replace(/\+/g, '-')
    .replace(/\//g, '_');
}

function base64UrlDecode(str) {
  str = str.replace(/-/g, '+').replace(/_/g, '/');
  while (str.length % 4) str += '=';
  return Buffer.from(str, 'base64');
}

function signJwt(payload, secret, expiresInSeconds) {
  const header = { alg: 'HS256', typ: 'JWT' };
  const now = Math.floor(Date.now() / 1000);
  const claim = Object.assign({}, payload, {
    iat: now,
    exp: now + expiresInSeconds,
  });
  
  const encodedHeader = base64UrlEncode(JSON.stringify(header));
  const encodedPayload = base64UrlEncode(JSON.stringify(claim));
  const signatureInput = `${encodedHeader}.${encodedPayload}`;
  const signature = crypto
    .createHmac('sha256', secret)
    .update(signatureInput)
    .digest('base64')
    .replace(/=/g, '')
    .replace(/\+/g, '-')
    .replace(/\//g, '_');
    
  return `${signatureInput}.${signature}`;
}

function verifyJwt(token, secret) {
  const parts = token.split('.');
  if (parts.length !== 3) return null;
  
  const [encodedHeader, encodedPayload, signature] = parts;
  const signatureInput = `${encodedHeader}.${encodedPayload}`;
  const expectedSignature = crypto
    .createHmac('sha256', secret)
    .update(signatureInput)
    .digest('base64')
    .replace(/=/g, '')
    .replace(/\+/g, '-')
    .replace(/\//g, '_');
    
  if (signature !== expectedSignature) return null;
  
  try {
    const payload = JSON.parse(base64UrlDecode(encodedPayload).toString('utf8'));
    const now = Math.floor(Date.now() / 1000);
    if (payload.exp && payload.exp < now) return null;
    return payload;
  } catch (e) {
    return null;
  }
}

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

  // --- Security Check: Auth Token ---
  // STRICT MODE: Only accept valid JWT tokens signed by JWT_SECRET
  const clientToken = (req.headers['x-airread-token'] || '').trim();
  const jwtSecret = (process.env.JWT_SECRET || '').trim();
  const requiresAuth = action !== 'TextTranslate';

  if (requiresAuth) {
    if (!jwtSecret) {
      return sendJson(res, 500, { error: 'ServerMisconfiguration', message: 'JWT_SECRET must be set' });
    }

    const claim = verifyJwt(clientToken, jwtSecret);
    if (!claim) {
      return sendJson(res, 401, { error: 'Unauthorized', message: 'Invalid or missing JWT token' });
    }

    const scopes = claim.scopes || [];
    const isTtsRequest = action === 'TextToVoice';
    if (isTtsRequest) {
      if (!scopes.includes('tts')) {
        return sendJson(res, 403, { error: 'Forbidden', message: 'TTS scope required' });
      }
    } else {
      if (!scopes.includes('vip')) {
        return sendJson(res, 403, { error: 'Forbidden', message: 'VIP scope required' });
      }
    }
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

  // --- Security Check: Signature Verification ---
  const pubKeyB64 = process.env.LICENSE_PUBLIC_KEY;
  if (pubKeyB64) {
    try {
      const raw = licenseCode;
      let type = 'vip'; // default
      if (raw.startsWith('A3')) {
        type = 'vip';
      } else if (raw.startsWith('T3')) {
        type = 'tts';
      } else {
        throw new Error('Invalid version');
      }
      
      const content = raw.substring(2);
      const bytes = base64UrlDecode(content);
      // Payload: 1 byte dayIndex + 4 bytes nonce = 5 bytes
      const payloadLen = 5; 
      const sigLen = 64;
      if (bytes.length !== payloadLen + sigLen) throw new Error('Invalid length');
      
      const payload = bytes.slice(0, payloadLen);
      const signature = bytes.slice(payloadLen);
      
      const publicKey = getEd25519PublicKey(pubKeyB64);
      const valid = verifyEd25519(payload, signature, publicKey);
      if (!valid) {
        return sendJson(res, 403, { error: 'Invalid license signature' });
      }
      
      // Store type for token issuance
      req.licenseType = type;
      req.licenseIndex = payload[0];

    } catch (e) {
      console.error('License verification failed:', e);
      return sendJson(res, 400, { error: 'Invalid license format', details: e.message });
    }
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

    // --- Issue Token ---
    let token = null;
    const jwtSecret = process.env.JWT_SECRET;
    if (jwtSecret) {
      // Determine duration based on type and index
      let durationSeconds = 30 * 86400; // default 30 days
      const type = req.licenseType || 'vip';
      const index = req.licenseIndex || 0;
      
      if (type === 'vip') {
        // [1, 7, 15, 30, 60, 180, 360] days
        const map = [1, 7, 15, 30, 60, 180, 360];
        const days = (index >= 0 && index < map.length) ? map[index] : 30;
        durationSeconds = (days + 1) * 86400; // Add buffer
      } else if (type === 'tts') {
        // [1, 5, 20, 50, 100] hours
        const map = [1, 5, 20, 50, 100];
        const hours = (index >= 0 && index < map.length) ? map[index] : 1;
        // Buffer: Give extra 24 hours just in case, or tight?
        // If user buys 1 hour, token expires in 1 hour.
        // But if we want to be generous for connection issues, maybe 1 hour + buffer.
        // Let's say exact hours + 1 hour buffer.
        durationSeconds = (hours * 3600) + 3600;
      }

      const scopes = type === 'vip' ? ['vip'] : ['tts'];
      token = signJwt({ sub: deviceId, license: codeHash, scopes }, jwtSecret, durationSeconds);
    }

    sendJson(res, 200, { message: 'License redeemed successfully', used: false, token });

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
