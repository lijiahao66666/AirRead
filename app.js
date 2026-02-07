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

function charCount(s) {
  if (!s) return 0;
  try {
    return [...String(s)].length;
  } catch (_) {
    return String(s).length;
  }
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

async function cosGetObject({ bucket, region, key, credentials }) {
  const resp = await cosRequest({
    method: 'GET',
    bucket,
    region,
    key,
    headers: {},
    query: {},
    credentials,
  });
  if ((resp.statusCode || 0) !== 200) {
    throw new Error(`COS GET ${key} status=${resp.statusCode || 0}`);
  }
  return resp.body || Buffer.from('');
}

async function cosPutJson({ bucket, region, key, json, headers, credentials }) {
  const body = Buffer.from(JSON.stringify(json));
  const resp = await cosRequest({
    method: 'PUT',
    bucket,
    region,
    key,
    headers: Object.assign(
      {
        'content-length': String(body.length),
        'content-type': 'application/json; charset=utf-8',
      },
      headers || {}
    ),
    query: {},
    body,
    credentials,
  });
  return resp.statusCode || 0;
}

async function getPointsBalance({ bucket, region, deviceId, credentials }) {
  const key = `points/${deviceId}.json`;
  try {
    const buf = await cosGetObject({ bucket, region, key, credentials });
    const obj = JSON.parse(buf.toString('utf8'));
    const prev = Number(obj && obj.balance ? obj.balance : 0) || 0;
    return prev < 0 ? 0 : prev;
  } catch (_) {
    return 0;
  }
}

async function setPointsBalance({ bucket, region, deviceId, balance, credentials }) {
  const key = `points/${deviceId}.json`;
  const next = balance < 0 ? 0 : balance;
  const status = await cosPutJson({
    bucket,
    region,
    key,
    json: { balance: next, updatedAt: new Date().toISOString() },
    headers: {},
    credentials,
  });
  if (status < 200 || status >= 300) {
    throw new Error(`COS Put Points Error: ${status}`);
  }
  return next;
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
    'aiart.tencentcloudapi.com',
  ]);
  return allow.has(String(host || '').toLowerCase());
}

function isAllowedAction(action) {
  const allow = new Set(['ChatCompletions', 'ChatTranslations', 'TextToVoice', 'TextTranslate', 'SubmitTextToImageJob', 'QueryTextToImageJob']);
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
    secretId: requestSecretIdRaw,
    secretKey: requestSecretKeyRaw,
  } = body || {};

  if (!host || !service || !action || !version || !payload) {
    return sendJson(res, 400, { error: 'BadRequest', message: 'Missing required fields' });
  }

  const requestSecretId = String(requestSecretIdRaw || '').trim();
  const requestSecretKey = String(requestSecretKeyRaw || '').trim();
  const usingPersonalKeys = Boolean(requestSecretId && requestSecretKey);

  // --- Security Check: Auth Token ---
  // Only online big model translation / QA / TTS require JWT.
  const clientToken = (req.headers['x-airread-token'] || '').trim();
  const jwtSecret = (process.env.JWT_SECRET || '').trim();
  const requiresAuth = !usingPersonalKeys && String(action) !== 'TextTranslate';

  if (requiresAuth) {
    if (!jwtSecret) {
      return sendJson(res, 500, { error: 'ServerMisconfiguration', message: 'JWT_SECRET must be set' });
    }

    const claim = verifyJwt(clientToken, jwtSecret);
    if (!claim) {
      return sendJson(res, 401, { error: 'Unauthorized', message: 'Invalid or missing JWT token' });
    }

    // Points-based system: token validity only, no scope separation
    req.jwtClaim = claim;
  }

  const bucket = process.env.BUCKET_NAME;
  const regionEnv = process.env.REGION;
  const deviceId = (req.jwtClaim && req.jwtClaim.sub)
      ? String(req.jwtClaim.sub).trim()
      : '';
  const canAccountPoints = !usingPersonalKeys && Boolean(bucket && regionEnv && deviceId);
  const regionStr = regionEnv;
  let inputChars = 0;
  let outputChars = 0;
  let unitCost = 1;

  if (canAccountPoints) {
    if (action === 'ChatCompletions') {
      const msgs = Array.isArray(payload && payload.Messages) ? payload.Messages : [];
      inputChars = msgs.reduce((acc, m) => acc + charCount(m && m.Content), 0);
      unitCost = 1;
    } else if (action === 'ChatTranslations') {
      inputChars = charCount(payload && payload.Text);
      unitCost = 1;
    } else if (action === 'TextToVoice') {
      inputChars = charCount(payload && payload.Text);
      unitCost = 10;
    } else if (action === 'TextTranslate') {
      inputChars = charCount(payload && payload.SourceText);
      unitCost = 1;
    } else if (action === 'SubmitTextToImageJob') {
      inputChars = 20000; // Fixed cost per image generation
      unitCost = 1;
    } else if (action === 'QueryTextToImageJob') {
      inputChars = 0;
      unitCost = 1;
    }
  }

  if (!isAllowedHost(host) || !isAllowedAction(action)) {
    return sendJson(res, 403, { error: 'Forbidden', message: 'Host or action not allowed' });
  }

  const envSecretId = String(process.env.TENCENT_SECRET_ID || '').trim();
  const envSecretKey = String(process.env.TENCENT_SECRET_KEY || '').trim();
  const secretId = usingPersonalKeys ? requestSecretId : envSecretId;
  const secretKey = usingPersonalKeys ? requestSecretKey : envSecretKey;
  if (!secretId || !secretKey) {
    return sendJson(res, 500, { error: 'MissingCredentials', message: usingPersonalKeys ? 'Missing secretId / secretKey in request' : 'Set TENCENT_SECRET_ID / TENCENT_SECRET_KEY' });
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

  let streamBalanceAfterInput = null;
  if (canAccountPoints && useStream) {
    try {
      const current = await getPointsBalance({
        bucket,
        region: regionStr,
        deviceId,
        credentials: null,
      });
      const need = inputChars * unitCost;
      if (current < need) {
        return sendJson(res, 402, { error: 'PointsInsufficient', message: '积分不足，无法开始流式请求', need, balance: current });
      }
      streamBalanceAfterInput = await setPointsBalance({
        bucket,
        region: regionStr,
        deviceId,
        balance: current - need,
        credentials: null,
      });
    } catch (_) {
    }
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

      let sseBuffer = '';
      let doneSeen = false;
      upstreamRes.on('data', (chunk) => {
        const text = chunk.toString('utf8');
        sseBuffer += text;
        while (true) {
          const idx = sseBuffer.indexOf('\n');
          if (idx === -1) break;
          const line = sseBuffer.substring(0, idx);
          sseBuffer = sseBuffer.substring(idx + 1);
          if (line.startsWith('data: ')) {
            const jsonStr = line.substring(6).trim();
            if (jsonStr === '[DONE]') {
              doneSeen = true;
              continue;
            }
            if (jsonStr !== '[DONE]') {
              try {
                const obj = JSON.parse(jsonStr);
                const choices = obj && obj.Choices;
                if (Array.isArray(choices) && choices.length > 0) {
                  const first = choices[0];
                  const delta = first && first.Delta;
                  const msg = first && first.Message;
                  if (delta && typeof delta === 'object' && delta.Content) {
                    outputChars += charCount(delta.Content);
                  } else if (msg && typeof msg === 'object' && msg.Content) {
                    outputChars += charCount(msg.Content);
                  } else if (first && typeof first.Content === 'string') {
                    outputChars += charCount(first.Content);
                  }
                }
              } catch (_) {
              }
            }
          }
          res.write(line + '\n');
        }
      });
      upstreamRes.on('end', async () => {
        if (sseBuffer.length > 0) {
          res.write(sseBuffer);
        }
        if (canAccountPoints) {
          let nextBalance = null;
          try {
            const extraNeed = outputChars * unitCost;
            if (extraNeed > 0) {
              const current = await getPointsBalance({
                bucket,
                region: regionStr,
                deviceId,
                credentials: null,
              });
              nextBalance = await setPointsBalance({
                bucket,
                region: regionStr,
                deviceId,
                balance: current - extraNeed,
                credentials: null,
              });
            }
          } catch (_) {
          }
          if (nextBalance === null && streamBalanceAfterInput !== null) {
            nextBalance = streamBalanceAfterInput;
          }
          if (nextBalance !== null) {
            res.write(`data: ${JSON.stringify({ PointsBalance: nextBalance })}\n\n`);
          }
        }
        if (doneSeen) {
          res.write('data: [DONE]\n\n');
        }
        res.end();
      });
      upstreamRes.on('error', () => res.end());

      req.on('close', () => {
        try { upstreamReq.destroy(); } catch (_) {}
      });
      return;
    }

    let buf = [];
    upstreamRes.on('data', (c) => buf.push(c));
    upstreamRes.on('end', async () => {
      const raw = Buffer.concat(buf).toString('utf8');
      if ((upstreamRes.statusCode || 500) < 200 || (upstreamRes.statusCode || 500) >= 300) {
        sendJson(res, upstreamRes.statusCode || 500, { error: 'UpstreamHttpError', status: upstreamRes.statusCode, body: raw });
        return;
      }
      try {
        const json = JSON.parse(raw);
        if (canAccountPoints) {
          try {
            if (action === 'ChatCompletions') {
              const choices = (json && json.Choices) || (json && json.Response && json.Response.Choices);
              if (Array.isArray(choices) && choices.length > 0) {
                const first = choices[0];
                const msg = first && first.Message;
                if (msg && typeof msg === 'object' && msg.Content) {
                  outputChars = charCount(msg.Content);
                } else if (first && typeof first.Content === 'string') {
                  outputChars = charCount(first.Content);
                }
              }
            } else if (action === 'ChatTranslations') {
              const choices = (json && json.Choices) || (json && json.Response && json.Response.Choices);
              if (Array.isArray(choices) && choices.length > 0) {
                const first = choices[0];
                const msg = first && first.Message;
                if (msg && typeof msg === 'object' && msg.Content) {
                  outputChars = charCount(msg.Content);
                } else if (first && typeof first.Content === 'string') {
                  outputChars = charCount(first.Content);
                }
              }
            } else if (action === 'TextTranslate') {
              outputChars = charCount((json && json.TargetText) || (json && json.Response && json.Response.TargetText));
            } else if (action === 'TextToVoice' || action === 'SubmitTextToImageJob' || action === 'QueryTextToImageJob') {
              outputChars = 0;
            }
            const totalNeed = (inputChars * unitCost) + (outputChars * unitCost);
            const current = await getPointsBalance({
              bucket,
              region: regionStr,
              deviceId,
              credentials: null,
            });
            if (current < totalNeed) {
              sendJson(res, 402, { error: 'PointsInsufficient', message: '积分不足，无法完成请求', need: totalNeed, balance: current });
              return;
            }
            const next = await setPointsBalance({
              bucket,
              region: regionStr,
              deviceId,
              balance: current - totalNeed,
              credentials: null,
            });
            json.PointsDeducted = totalNeed;
            json.PointsBalance = next;
          } catch (e) {
            json.PointsError = String(e && e.message ? e.message : e);
            try {
               const current = await getPointsBalance({ bucket, region: regionStr, deviceId, credentials: null });
               json.PointsBalance = current;
            } catch (_) {}
          }
        }
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
      if (!raw.startsWith('P3')) {
        throw new Error('Invalid version');
      }
      const content = raw.substring(2);
      const bytes = base64UrlDecode(content);
      // Payload: 1 byte pointsIndex + 4 bytes nonce = 5 bytes
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
      
      // Store points index for accumulation
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

    // --- Accumulate Points ---
    const index = req.licenseIndex || 0;
    const pointsMap = [50000, 100000, 200000, 500000, 1000000];
    const points = (index >= 0 && index < pointsMap.length) ? pointsMap[index] : 0;
    if (points <= 0) {
      throw new Error('Unsupported points index');
    }

    const pointsKey = `points/${deviceId}.json`;
    let prev = 0;
    try {
      const buf = await cosGetObject({ bucket, region, key: pointsKey, credentials });
      const obj = JSON.parse(buf.toString('utf8'));
      prev = Number(obj && obj.balance ? obj.balance : 0) || 0;
    } catch (_) {
      prev = 0;
    }
    const nextBalance = prev + points;
    const putPointsStatus = await cosPutJson({
      bucket,
      region,
      key: pointsKey,
      json: { balance: nextBalance, updatedAt: new Date().toISOString() },
      headers: {},
      credentials,
    });
    if (putPointsStatus < 200 || putPointsStatus >= 300) {
      throw new Error(`COS Put Points Error: ${putPointsStatus}`);
    }

    // --- Issue Token (points scope, long-lived) ---
    let token = null;
    const jwtSecret = process.env.JWT_SECRET;
    if (jwtSecret) {
      const durationSeconds = 365 * 86400; // 1 year
      token = signJwt({ sub: deviceId, license: codeHash, scopes: ['points'] }, jwtSecret, durationSeconds);
    }

    sendJson(res, 200, { message: 'License redeemed successfully', used: false, token, pointsAdded: points, balance: nextBalance });

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
