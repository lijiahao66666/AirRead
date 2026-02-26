'use strict';

const http = require('http');
const https = require('https');
const crypto = require('crypto');
const fs = require('fs');
const path = require('path');

// --- Helper: JWT (HS256) ---
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
 * AirRead Unified API Server (Lightweight Cloud)
 *
 * Capabilities:
 * 1. Proxy Tencent Cloud API requests (Hunyuan, TTS, TMT) with server-side signing.
 * 2. Points-based billing (local JSON files).
 * 3. Remote config endpoint (/config).
 *
 * Environment Variables Required:
 * - TENCENT_SECRET_ID / TENCENT_SECRET_KEY: For signing Tencent Cloud API requests.
 * - JWT_SECRET: (Optional) For auth token verification.
 * - JWT_OPTIONAL: (Optional) Set to "1" to skip JWT auth (for development/initial launch).
 * - PORT: (Optional) Default 9000.
 *
 * Data stored locally:
 * - ./config.json: Remote config for App.
 * - ./data/points/{deviceId}.json: Points balance per device.
 */

// --- Helper: HMAC ---
function hmacSha256(key, msg, encoding) {
  return crypto.createHmac('sha256', key).update(msg, 'utf8').digest(encoding);
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

// --- Local Points Storage (replaces COS) ---
const DATA_DIR = path.join(__dirname, 'data', 'points');
if (!fs.existsSync(DATA_DIR)) {
  fs.mkdirSync(DATA_DIR, { recursive: true });
}

function _pointsFile(deviceId) {
  // Sanitize deviceId to prevent path traversal
  const safe = String(deviceId || 'unknown').replace(/[^a-zA-Z0-9_\-]/g, '_');
  return path.join(DATA_DIR, `${safe}.json`);
}

async function getPointsBalance({ deviceId }) {
  try {
    const file = _pointsFile(deviceId);
    if (!fs.existsSync(file)) return 0;
    const obj = JSON.parse(fs.readFileSync(file, 'utf-8'));
    const prev = Number(obj && obj.balance ? obj.balance : 0) || 0;
    return prev < 0 ? 0 : prev;
  } catch (_) {
    return 0;
  }
}

async function setPointsBalance({ deviceId, balance }) {
  const next = balance < 0 ? 0 : balance;
  const file = _pointsFile(deviceId);
  fs.writeFileSync(file, JSON.stringify({ balance: next, updatedAt: new Date().toISOString() }), 'utf-8');
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

const _actionConcurrencyLimit = new Map([
  ['SubmitTextToImageJob', 1],
  ['QueryTextToImageJob', 5],
  ['ChatCompletions', 5],
  ['ChatTranslations', 5],
  ['TextToVoice', 20],
  ['TextTranslate', 5],
]);

const _actionActiveCount = new Map();
function _tryAcquireActionSlot(action) {
  const a = String(action || '');
  const limit = _actionConcurrencyLimit.has(a) ? _actionConcurrencyLimit.get(a) : 5;
  const active = _actionActiveCount.get(a) || 0;
  if (active >= limit) return null;
  _actionActiveCount.set(a, active + 1);
  let released = false;
  return () => {
    if (released) return;
    released = true;
    const cur = _actionActiveCount.get(a) || 0;
    _actionActiveCount.set(a, cur > 0 ? cur - 1 : 0);
  };
}

const _activeImageJobs = new Map();
const _imageJobTtlMs = 20 * 60 * 1000;
function _pruneActiveImageJobs() {
  const now = Date.now();
  for (const [jobId, ts] of _activeImageJobs.entries()) {
    if (!Number.isFinite(ts) || (now - ts) > _imageJobTtlMs) {
      _activeImageJobs.delete(jobId);
    }
  }
}

function _canStartNewImageJob() {
  _pruneActiveImageJobs();
  return _activeImageJobs.size < 1;
}

function _markImageJobActive(jobId) {
  const id = String(jobId || '').trim();
  if (!id) return;
  _activeImageJobs.set(id, Date.now());
}

function _markImageJobDone(jobId) {
  const id = String(jobId || '').trim();
  if (!id) return;
  _activeImageJobs.delete(id);
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
  let clientToken = String(req.headers['x-airread-token'] || '').trim();
  if (!clientToken) {
    const auth = String(req.headers['authorization'] || '').trim();
    const m = auth.match(/^Bearer\s+(.+)$/i);
    if (m) clientToken = String(m[1] || '').trim();
  }
  const jwtSecret = (process.env.JWT_SECRET || '').trim();
  const requiresAuth = !usingPersonalKeys && String(action) !== 'TextTranslate';

  if (requiresAuth) {
    if (!jwtSecret) {
      return sendJson(res, 500, { error: 'ServerMisconfiguration', message: 'JWT_SECRET must be set' });
    }

    const claim = verifyJwt(clientToken, jwtSecret);
    if (!claim) {
      const jwtOptional = String(process.env.JWT_OPTIONAL || '').trim() === '1';
      const jwtOptionalHeader = String(process.env.JWT_OPTIONAL_HEADER || '').trim() === '1';
      const debugNoJwtHeader = String(req.headers['x-airread-debug-nojwt'] || '').trim() === '1';
      const remote = String(req.socket && req.socket.remoteAddress ? req.socket.remoteAddress : '').trim();
      const fromLocal = (remote === '127.0.0.1' || remote === '::1' || remote.endsWith('127.0.0.1'));
      const allowNoJwt = jwtOptional || (jwtOptionalHeader && debugNoJwtHeader && fromLocal);
      if (!allowNoJwt) {
        return sendJson(res, 401, { error: 'Unauthorized', message: 'Invalid or missing JWT token' });
      }
      req.jwtClaim = null;
    } else {
      // Points-based system: token validity only, no scope separation
      req.jwtClaim = claim;
    }
  }

  const deviceId = (req.jwtClaim && req.jwtClaim.sub)
      ? String(req.jwtClaim.sub).trim()
      : '';
  const canAccountPoints = !usingPersonalKeys && Boolean(deviceId);
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
      inputChars = 0;
      unitCost = 1;
    } else if (action === 'QueryTextToImageJob') {
      inputChars = 0;
      unitCost = 1;
    }
  }

  if (!isAllowedHost(host) || !isAllowedAction(action)) {
    return sendJson(res, 403, { error: 'Forbidden', message: 'Host or action not allowed' });
  }

  if (action === 'SubmitTextToImageJob' && !_canStartNewImageJob()) {
    const retryAfterMs = 1200;
    res.setHeader('Retry-After', String(Math.ceil(retryAfterMs / 1000)));
    return sendJson(res, 429, { error: 'QueueBusy', message: '上一张出图未完成，请稍后重试', retryAfterMs });
  }

  const releaseSlot = _tryAcquireActionSlot(action);
  if (!releaseSlot) {
    const retryAfterMs = 900;
    res.setHeader('Retry-After', String(Math.ceil(retryAfterMs / 1000)));
    return sendJson(res, 429, { error: 'QueueBusy', message: '系统繁忙，请稍后重试', retryAfterMs });
  }
  let slotReleased = false;
  function safeReleaseSlot() {
    if (slotReleased) return;
    slotReleased = true;
    try { releaseSlot(); } catch (_) {}
  }

  const envSecretId = String(process.env.TENCENT_SECRET_ID || '').trim();
  const envSecretKey = String(process.env.TENCENT_SECRET_KEY || '').trim();
  const secretId = usingPersonalKeys ? requestSecretId : envSecretId;
  const secretKey = usingPersonalKeys ? requestSecretKey : envSecretKey;
  if (!secretId || !secretKey) {
    safeReleaseSlot();
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
      const current = await getPointsBalance({ deviceId });
      const need = inputChars * unitCost;
      if (current < need) {
        safeReleaseSlot();
        return sendJson(res, 402, { error: 'PointsInsufficient', message: '积分不足，无法开始流式请求', need, balance: current });
      }
      streamBalanceAfterInput = await setPointsBalance({
        deviceId,
        balance: current - need,
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
        try {
          if (sseBuffer.length > 0) {
            res.write(sseBuffer);
          }
          if (canAccountPoints) {
            let nextBalance = null;
            try {
              const extraNeed = outputChars * unitCost;
              if (extraNeed > 0) {
                const current = await getPointsBalance({ deviceId });
                nextBalance = await setPointsBalance({
                  deviceId,
                  balance: current - extraNeed,
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
        } finally {
          safeReleaseSlot();
        }
      });
      upstreamRes.on('error', () => {
        try { res.end(); } catch (_) {}
        safeReleaseSlot();
      });

      req.on('close', () => {
        try { upstreamReq.destroy(); } catch (_) {}
        safeReleaseSlot();
      });
      return;
    }

    let buf = [];
    upstreamRes.on('data', (c) => buf.push(c));
    upstreamRes.on('error', () => {
      try { res.end(); } catch (_) {}
      safeReleaseSlot();
    });
    upstreamRes.on('end', async () => {
      try {
        const raw = Buffer.concat(buf).toString('utf8');
        if ((upstreamRes.statusCode || 500) < 200 || (upstreamRes.statusCode || 500) >= 300) {
          sendJson(res, upstreamRes.statusCode || 500, { error: 'UpstreamHttpError', status: upstreamRes.statusCode, body: raw });
          return;
        }
        try {
          const json = JSON.parse(raw);
          if (action === 'SubmitTextToImageJob') {
            const respObj = (json && json.Response) ? json.Response : json;
            const jobId = respObj && respObj.JobId;
            if (jobId) _markImageJobActive(jobId);
          } else if (action === 'QueryTextToImageJob') {
            const respObj = (json && json.Response) ? json.Response : json;
            const jobStatusRaw = respObj && respObj.JobStatusCode;
            const jobStatus = Number.isFinite(Number(jobStatusRaw)) ? Number(jobStatusRaw) : 0;
            const jobId = respObj && respObj.JobId;
            if ((jobStatus === 4 || jobStatus === 5) && jobId) {
              _markImageJobDone(jobId);
            }
          }
          if (canAccountPoints && action !== 'SubmitTextToImageJob' && action !== 'QueryTextToImageJob') {
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
              const current = await getPointsBalance({ deviceId });
              if (current < totalNeed) {
                sendJson(res, 402, { error: 'PointsInsufficient', message: '积分不足，无法完成请求', need: totalNeed, balance: current });
                return;
              }
              const next = await setPointsBalance({
                deviceId,
                balance: current - totalNeed,
              });
              json.PointsDeducted = totalNeed;
              json.PointsBalance = next;
            } catch (e) {
              json.PointsError = String(e && e.message ? e.message : e);
              try {
                 const current = await getPointsBalance({ deviceId });
                 json.PointsBalance = current;
              } catch (_) {}
            }
          }
          sendJson(res, 200, json);
        } catch (_) {
          sendJson(res, 200, { body: raw, contentType });
        }
      } finally {
        safeReleaseSlot();
      }
    });
  });

  upstreamReq.on('error', (e) => {
    safeReleaseSlot();
    if (!res.headersSent) sendJson(res, 502, { error: 'BadGateway', message: String(e && e.message ? e.message : e) });
    else res.end();
  });

  upstreamReq.write(upstreamPayloadJson);
  upstreamReq.end();
}

// --- Remote Config ---
const CONFIG_FILE = path.join(__dirname, 'config.json');
const DEFAULT_CONFIG = {
  checkin_enabled: true,
  checkin_points: 5000,
  initial_grant_points: 500000,
  ad_enabled: false,
  ad_reward_points: 2000,
  ad_daily_limit: 10,
  purchase_enabled: false,
  latest_version: '1.0.0',
  min_version: '1.0.0',
  update_url: '',
  update_message: '',
  force_update: false,
  announcement: '',
};

function loadConfig() {
  try {
    if (fs.existsSync(CONFIG_FILE)) {
      return JSON.parse(fs.readFileSync(CONFIG_FILE, 'utf-8'));
    }
  } catch (e) {
    console.error('[config] Failed to load config.json:', e.message);
  }
  return DEFAULT_CONFIG;
}

if (!fs.existsSync(CONFIG_FILE)) {
  fs.writeFileSync(CONFIG_FILE, JSON.stringify(DEFAULT_CONFIG, null, 2), 'utf-8');
  console.log('[config] Created default ' + CONFIG_FILE);
}

// --- Main Server ---
const server = http.createServer(async (req, res) => {
  // CORS
  res.setHeader('Access-Control-Allow-Origin', '*');
  res.setHeader('Access-Control-Allow-Headers', 'content-type,x-airread-token,authorization,accept');
  res.setHeader('Access-Control-Allow-Methods', 'GET, POST, OPTIONS');

  if (req.method === 'OPTIONS') {
    res.writeHead(204);
    res.end();
    return;
  }

  // GET /config — Remote config for App
  if (req.method === 'GET' && req.url === '/config') {
    const config = loadConfig();
    res.writeHead(200, { 'Content-Type': 'application/json; charset=utf-8' });
    res.end(JSON.stringify(config));
    return;
  }

  // GET / or /health — Health check
  if (req.method === 'GET' && (req.url === '/' || req.url === '/health')) {
    res.writeHead(200, { 'Content-Type': 'text/plain' });
    res.end('OK');
    return;
  }

  // POST — API proxy
  if (req.method === 'POST') {
    let body;
    try {
      body = await readJsonBody(req);
    } catch (e) {
      sendJson(res, 400, { error: 'InvalidJson', message: String(e && e.message ? e.message : e) });
      return;
    }
    await handleApiProxy(req, res, body);
    return;
  }

  sendJson(res, 405, { error: 'MethodNotAllowed' });
});

const port = process.env.PORT ? Number(process.env.PORT) : 9000;
server.listen(port, () => {
  console.log(`[AirRead API Server] listening on port ${port}`);
  console.log(`[AirRead API Server] GET  http://localhost:${port}/config`);
  console.log(`[AirRead API Server] POST http://localhost:${port}/ (API proxy)`);
});
