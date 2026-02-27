'use strict';

const http = require('http');
const https = require('https');
const crypto = require('crypto');
const fs = require('fs');
const path = require('path');

// --- Helper: API Key Check ---
function verifyApiKey(req) {
  const serverKey = (process.env.API_KEY || '').trim();
  if (!serverKey) return true; // No API_KEY configured = allow all (dev mode)
  const clientKey = String(req.headers['x-api-key'] || '').trim();
  return clientKey === serverKey;
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
 * - API_KEY: (Optional) Static API key for request authentication.
 * - PORT: (Optional) Default 9000.
 *
 * Data stored locally:
 * - ./config.json: Remote config for App.
 * - ./data/points/{deviceId}.json: Points balance per device.
 */

// --- Helper: Crypto ---
function sha256Hex(msg) {
  return crypto.createHash('sha256').update(msg, 'utf8').digest('hex');
}

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

// --- User Auth Storage ---
const USERS_DIR = path.join(__dirname, 'data', 'users');
const SMS_DIR = path.join(__dirname, 'data', 'sms');
const TOKENS_DIR = path.join(__dirname, 'data', 'tokens');
const STATS_DIR = path.join(__dirname, 'data', 'stats', 'daily');
[USERS_DIR, SMS_DIR, TOKENS_DIR, STATS_DIR].forEach(d => {
  if (!fs.existsSync(d)) fs.mkdirSync(d, { recursive: true });
});

// --- SMS: Tencent Cloud SMS API ---
function _smsFile(phone) {
  const safe = String(phone).replace(/[^0-9]/g, '');
  return path.join(SMS_DIR, `${safe}.json`);
}

function _generateCode() {
  return String(Math.floor(100000 + Math.random() * 900000));
}

async function sendSmsCode(phone) {
  const safe = String(phone).replace(/[^0-9]/g, '');
  if (safe.length !== 11) return { error: 'InvalidPhone' };

  // Rate limit: 60s per phone, 10 per day
  const file = _smsFile(safe);
  let smsData = null;
  try {
    if (fs.existsSync(file)) smsData = JSON.parse(fs.readFileSync(file, 'utf-8'));
  } catch (_) {}

  const now = Date.now();
  const today = new Date().toISOString().substring(0, 10);

  if (smsData) {
    if (smsData.lastSentAt && (now - smsData.lastSentAt) < 60000) {
      return { error: 'TooFrequent', message: '发送太频繁，请60秒后重试' };
    }
    if (smsData.dailyDate === today && (smsData.dailyCount || 0) >= 10) {
      return { error: 'DailyLimit', message: '今日验证码发送次数已达上限' };
    }
  }

  const code = _generateCode();
  const expireAt = now + 5 * 60 * 1000; // 5 minutes

  // Send via Tencent Cloud SMS API
  const smsAppId = (process.env.SMS_APP_ID || '').trim();
  const smsSign = (process.env.SMS_SIGN || '').trim();
  const smsTemplateId = (process.env.SMS_TEMPLATE_ID || '').trim();
  const secretId = (process.env.TENCENT_SECRET_ID || '').trim();
  const secretKey = (process.env.TENCENT_SECRET_KEY || '').trim();

  if (!smsAppId || !smsSign || !smsTemplateId || !secretId || !secretKey) {
    console.error('[SMS] Missing SMS config env vars');
    return { error: 'SmsConfigError', message: '短信服务未配置' };
  }

  const smsPayload = {
    SmsSdkAppId: smsAppId,
    SignName: smsSign,
    TemplateId: smsTemplateId,
    TemplateParamSet: [code, '5'],
    PhoneNumberSet: [`+86${safe}`],
  };
  const smsPayloadJson = JSON.stringify(smsPayload);
  const ts = Math.floor(now / 1000);
  const smsHeaders = buildTc3Auth({
    secretId, secretKey,
    service: 'sms', host: 'sms.tencentcloudapi.com',
    action: 'SendSms', version: '2021-01-11',
    region: 'ap-guangzhou', timestampSeconds: ts,
    payloadJson: smsPayloadJson,
  });

  try {
    const smsResp = await new Promise((resolve, reject) => {
      const req = https.request({
        hostname: 'sms.tencentcloudapi.com',
        method: 'POST', path: '/',
        headers: smsHeaders,
      }, (res) => {
        let data = '';
        res.on('data', c => data += c);
        res.on('end', () => {
          try { resolve(JSON.parse(data)); } catch (e) { reject(e); }
        });
      });
      req.on('error', reject);
      req.write(smsPayloadJson);
      req.end();
    });

    const resp = smsResp.Response || smsResp;
    if (resp.Error) {
      console.error('[SMS] API error:', resp.Error);
      return { error: 'SmsSendFailed', message: resp.Error.Message || '短信发送失败' };
    }
    const sendStatus = resp.SendStatusSet && resp.SendStatusSet[0];
    if (sendStatus && sendStatus.Code !== 'Ok') {
      console.error('[SMS] Send status:', sendStatus);
      return { error: 'SmsSendFailed', message: sendStatus.Message || '短信发送失败' };
    }
  } catch (e) {
    console.error('[SMS] Request error:', e.message);
    return { error: 'SmsSendFailed', message: '短信发送失败' };
  }

  // Save code
  const dailyCount = (smsData && smsData.dailyDate === today) ? (smsData.dailyCount || 0) + 1 : 1;
  fs.writeFileSync(file, JSON.stringify({
    code, expireAt, lastSentAt: now,
    dailyDate: today, dailyCount,
  }, null, 2), 'utf-8');

  console.log(`[SMS] Sent code to ${safe.substring(0, 3)}****${safe.substring(7)}`);
  return { success: true };
}

function verifySmsCode(phone, code) {
  const safe = String(phone).replace(/[^0-9]/g, '');
  const file = _smsFile(safe);
  if (!fs.existsSync(file)) return false;
  try {
    const data = JSON.parse(fs.readFileSync(file, 'utf-8'));
    if (Date.now() > data.expireAt) return false;
    if (data.code !== String(code).trim()) return false;
    // Invalidate after use
    fs.unlinkSync(file);
    return true;
  } catch (_) {
    return false;
  }
}

// --- User Management ---
function _userFile(phone) {
  const safe = String(phone).replace(/[^0-9]/g, '');
  return path.join(USERS_DIR, `${safe}.json`);
}

function _tokenFile(token) {
  const safe = String(token).replace(/[^a-zA-Z0-9_\-]/g, '');
  return path.join(TOKENS_DIR, `${safe}.json`);
}

function _generateUserId() {
  return 'u_' + crypto.randomBytes(8).toString('hex');
}

function _generateToken() {
  return crypto.randomBytes(32).toString('hex');
}

function findOrCreateUser(phone) {
  const safe = String(phone).replace(/[^0-9]/g, '');
  const file = _userFile(safe);
  const now = new Date().toISOString();

  if (fs.existsSync(file)) {
    const user = JSON.parse(fs.readFileSync(file, 'utf-8'));
    // Revoke old token
    if (user.token) {
      const oldTf = _tokenFile(user.token);
      try { if (fs.existsSync(oldTf)) fs.unlinkSync(oldTf); } catch (_) {}
    }
    // Issue new token
    const token = _generateToken();
    user.token = token;
    user.lastLoginAt = now;
    user.loginCount = (user.loginCount || 0) + 1;
    fs.writeFileSync(file, JSON.stringify(user, null, 2), 'utf-8');
    // Save token→userId mapping
    fs.writeFileSync(_tokenFile(token), JSON.stringify({ userId: user.userId, phone: safe }), 'utf-8');
    return user;
  }

  // New user
  const userId = _generateUserId();
  const token = _generateToken();
  const user = {
    userId, phone: safe, token,
    createdAt: now, lastLoginAt: now,
    loginCount: 1, devices: [],
  };
  fs.writeFileSync(file, JSON.stringify(user, null, 2), 'utf-8');
  fs.writeFileSync(_tokenFile(token), JSON.stringify({ userId, phone: safe }), 'utf-8');
  console.log(`[Auth] New user: ${userId} phone=${safe.substring(0, 3)}****${safe.substring(7)}`);
  return user;
}

function getUserByToken(token) {
  if (!token) return null;
  const tf = _tokenFile(token);
  if (!fs.existsSync(tf)) return null;
  try {
    const { userId, phone } = JSON.parse(fs.readFileSync(tf, 'utf-8'));
    const uf = _userFile(phone);
    if (!fs.existsSync(uf)) return null;
    const user = JSON.parse(fs.readFileSync(uf, 'utf-8'));
    // Verify token matches (in case of stale token file)
    if (user.token !== token) return null;
    return user;
  } catch (_) {
    return null;
  }
}

function revokeToken(token) {
  if (!token) return;
  const tf = _tokenFile(token);
  try { if (fs.existsSync(tf)) fs.unlinkSync(tf); } catch (_) {}
}

// --- Helper: Extract userId from request (token auth) ---
function getUserIdFromReq(req) {
  const token = String(req.headers['x-auth-token'] || '').trim();
  if (!token) return null;
  const user = getUserByToken(token);
  return user ? user.userId : null;
}

// --- DAU Statistics ---
function _statsFile(date) {
  return path.join(STATS_DIR, `${date}.json`);
}

function recordActivity({ userId, platform, action }) {
  const today = new Date().toISOString().substring(0, 10);
  const file = _statsFile(today);
  let stats;
  try {
    if (fs.existsSync(file)) {
      stats = JSON.parse(fs.readFileSync(file, 'utf-8'));
    }
  } catch (_) {}
  if (!stats) {
    stats = { date: today, activeUsers: [], newUsers: 0, platformBreakdown: {}, totalApiCalls: 0, totalPointsUsed: 0 };
  }
  if (!stats.activeUsers.includes(userId)) {
    stats.activeUsers.push(userId);
  }
  stats.dau = stats.activeUsers.length;
  if (platform) {
    stats.platformBreakdown[platform] = (stats.platformBreakdown[platform] || 0) + 1;
  }
  if (action === 'api_call') stats.totalApiCalls = (stats.totalApiCalls || 0) + 1;
  fs.writeFileSync(file, JSON.stringify(stats, null, 2), 'utf-8');
}

function _pointsFile(deviceId) {
  // Sanitize deviceId to prevent path traversal
  const safe = String(deviceId || 'unknown').replace(/[^a-zA-Z0-9_\-]/g, '_');
  return path.join(DATA_DIR, `${safe}.json`);
}

function _readPointsData(deviceId) {
  try {
    const file = _pointsFile(deviceId);
    if (!fs.existsSync(file)) return null;
    return JSON.parse(fs.readFileSync(file, 'utf-8'));
  } catch (_) {
    return null;
  }
}

function _writePointsData(deviceId, data) {
  const file = _pointsFile(deviceId);
  data.updatedAt = new Date().toISOString();
  fs.writeFileSync(file, JSON.stringify(data, null, 2), 'utf-8');
}

async function getPointsBalance({ deviceId }) {
  const obj = _readPointsData(deviceId);
  if (!obj) return 0;
  const prev = Number(obj.balance || 0);
  return prev < 0 ? 0 : prev;
}

async function setPointsBalance({ deviceId, balance }) {
  const next = balance < 0 ? 0 : balance;
  const obj = _readPointsData(deviceId) || {};
  obj.balance = next;
  _writePointsData(deviceId, obj);
  return next;
}

// Ensure device has received initial grant; returns current balance
async function ensureInitialGrant({ deviceId, config }) {
  let obj = _readPointsData(deviceId);
  if (!obj) {
    // Brand new device — grant initial points
    const grant = Number(config.initial_grant_points) || 500000;
    obj = { balance: grant, initialGranted: true, createdAt: new Date().toISOString() };
    _writePointsData(deviceId, obj);
    console.log(`[points] initial grant ${grant} to ${deviceId}`);
    return obj.balance;
  }
  if (!obj.initialGranted) {
    // Legacy file without grant flag — assume already granted (don't double-grant)
    obj.initialGranted = true;
    _writePointsData(deviceId, obj);
  }
  return Number(obj.balance || 0);
}

// Server-side checkin: returns { points, streak, alreadyDone } or null
async function doCheckin({ deviceId, config }) {
  if (!deviceId) return null;
  const today = new Date().toISOString().substring(0, 10);
  const yesterday = new Date(Date.now() - 86400000).toISOString().substring(0, 10);
  let obj = _readPointsData(deviceId) || { balance: 0 };

  const lastCheckin = obj.lastCheckinDate || '';
  if (lastCheckin === today) {
    return { points: 0, streak: obj.checkinStreak || 0, alreadyDone: true, balance: obj.balance };
  }

  let streak = Number(obj.checkinStreak || 0);
  streak = (lastCheckin === yesterday) ? streak + 1 : 1;

  const reward = Number(config.checkin_points) || 5000;
  obj.balance = (Number(obj.balance) || 0) + reward;
  obj.lastCheckinDate = today;
  obj.checkinStreak = streak;
  _writePointsData(deviceId, obj);
  console.log(`[checkin] ${deviceId} +${reward} streak=${streak}`);
  return { points: reward, streak, alreadyDone: false, balance: obj.balance };
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

  // --- Security Check: Static API Key ---
  if (!usingPersonalKeys && !verifyApiKey(req)) {
    return sendJson(res, 401, { error: 'Unauthorized', message: 'Invalid or missing API key' });
  }

  // Prefer userId (from token auth) over raw deviceId for points accounting
  const userId = getUserIdFromReq(req);
  const deviceId = userId || String(req.headers['x-device-id'] || '').trim();
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
  res.setHeader('Access-Control-Allow-Headers', 'content-type,x-api-key,x-device-id,x-auth-token,x-platform,accept');
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

  // === AUTH ENDPOINTS ===

  // POST /auth/sms/send — Send SMS verification code
  if (req.method === 'POST' && req.url === '/auth/sms/send') {
    if (!verifyApiKey(req)) return sendJson(res, 401, { error: 'Unauthorized' });
    let body;
    try { body = await readJsonBody(req); } catch (_) { return sendJson(res, 400, { error: 'InvalidJson' }); }
    const phone = String(body.phone || '').trim();
    if (!phone || phone.replace(/[^0-9]/g, '').length !== 11) {
      return sendJson(res, 400, { error: 'InvalidPhone', message: '请输入正确的手机号' });
    }
    const result = await sendSmsCode(phone);
    if (result.error) return sendJson(res, 429, result);
    return sendJson(res, 200, { success: true });
  }

  // POST /auth/sms/verify — Verify code and login/register
  if (req.method === 'POST' && req.url === '/auth/sms/verify') {
    if (!verifyApiKey(req)) return sendJson(res, 401, { error: 'Unauthorized' });
    let body;
    try { body = await readJsonBody(req); } catch (_) { return sendJson(res, 400, { error: 'InvalidJson' }); }
    const phone = String(body.phone || '').trim();
    const code = String(body.code || '').trim();
    if (!phone || !code) return sendJson(res, 400, { error: 'MissingFields' });

    if (!verifySmsCode(phone, code)) {
      return sendJson(res, 400, { error: 'InvalidCode', message: '验证码错误或已过期' });
    }

    const isNew = !fs.existsSync(_userFile(phone.replace(/[^0-9]/g, '')));
    const user = findOrCreateUser(phone);
    const config = loadConfig();

    // Ensure initial points grant for new user
    if (isNew) {
      await ensureInitialGrant({ deviceId: user.userId, config });
    }

    // Merge deviceId points into userId if deviceId provided
    const deviceId = String(req.headers['x-device-id'] || '').trim();
    if (deviceId && deviceId !== user.userId) {
      const devicePoints = _readPointsData(deviceId);
      if (devicePoints && devicePoints.balance > 0) {
        const userPoints = _readPointsData(user.userId) || { balance: 0 };
        // Only merge if device has more points (avoid double-granting)
        if (devicePoints.balance > userPoints.balance) {
          userPoints.balance = devicePoints.balance;
          userPoints.initialGranted = true;
          if (devicePoints.lastCheckinDate) userPoints.lastCheckinDate = devicePoints.lastCheckinDate;
          if (devicePoints.checkinStreak) userPoints.checkinStreak = devicePoints.checkinStreak;
          _writePointsData(user.userId, userPoints);
          console.log(`[Auth] Merged points from device ${deviceId} to user ${user.userId}: ${userPoints.balance}`);
        }
      }
    }

    // Record device
    if (deviceId && !user.devices.includes(deviceId)) {
      user.devices.push(deviceId);
      fs.writeFileSync(_userFile(phone.replace(/[^0-9]/g, '')), JSON.stringify(user, null, 2), 'utf-8');
    }

    const balance = await getPointsBalance({ deviceId: user.userId });
    const platform = String(req.headers['x-platform'] || '').trim();
    recordActivity({ userId: user.userId, platform, action: 'login' });

    return sendJson(res, 200, {
      token: user.token,
      userId: user.userId,
      phone: user.phone.substring(0, 3) + '****' + user.phone.substring(7),
      balance,
      isNewUser: isNew,
    });
  }

  // POST /auth/profile — Get user info (requires token)
  if (req.method === 'POST' && req.url === '/auth/profile') {
    if (!verifyApiKey(req)) return sendJson(res, 401, { error: 'Unauthorized' });
    const user = getUserByToken(String(req.headers['x-auth-token'] || '').trim());
    if (!user) return sendJson(res, 401, { error: 'NotLoggedIn', message: '未登录' });
    const balance = await getPointsBalance({ deviceId: user.userId });
    return sendJson(res, 200, {
      userId: user.userId,
      phone: user.phone.substring(0, 3) + '****' + user.phone.substring(7),
      balance,
      createdAt: user.createdAt,
      loginCount: user.loginCount,
    });
  }

  // POST /auth/logout — Logout (revoke token)
  if (req.method === 'POST' && req.url === '/auth/logout') {
    const token = String(req.headers['x-auth-token'] || '').trim();
    if (token) revokeToken(token);
    return sendJson(res, 200, { success: true });
  }

  // GET /stats/today — DAU stats for today (admin use)
  if (req.method === 'GET' && req.url === '/stats/today') {
    if (!verifyApiKey(req)) return sendJson(res, 401, { error: 'Unauthorized' });
    const today = new Date().toISOString().substring(0, 10);
    const file = _statsFile(today);
    if (!fs.existsSync(file)) return sendJson(res, 200, { date: today, dau: 0, activeUsers: [], totalApiCalls: 0 });
    try {
      const stats = JSON.parse(fs.readFileSync(file, 'utf-8'));
      return sendJson(res, 200, stats);
    } catch (_) {
      return sendJson(res, 200, { date: today, dau: 0 });
    }
  }

  // === POINTS & CHECKIN ENDPOINTS (now use userId via token, fallback to deviceId) ===

  // POST /points/init — Initialize (ensure initial grant), return balance
  if (req.method === 'POST' && req.url === '/points/init') {
    if (!verifyApiKey(req)) return sendJson(res, 401, { error: 'Unauthorized' });
    const userId = getUserIdFromReq(req);
    const deviceId = userId || String(req.headers['x-device-id'] || '').trim();
    if (!deviceId) return sendJson(res, 400, { error: 'MissingIdentity', message: '请先登录' });
    const config = loadConfig();
    const balance = await ensureInitialGrant({ deviceId, config });
    return sendJson(res, 200, { balance });
  }

  // POST /points/balance — Get current balance
  if (req.method === 'POST' && req.url === '/points/balance') {
    if (!verifyApiKey(req)) return sendJson(res, 401, { error: 'Unauthorized' });
    const userId = getUserIdFromReq(req);
    const deviceId = userId || String(req.headers['x-device-id'] || '').trim();
    if (!deviceId) return sendJson(res, 400, { error: 'MissingIdentity' });
    const balance = await getPointsBalance({ deviceId });
    return sendJson(res, 200, { balance });
  }

  // POST /checkin/status — Check if already checked in today
  if (req.method === 'POST' && req.url === '/checkin/status') {
    if (!verifyApiKey(req)) return sendJson(res, 401, { error: 'Unauthorized' });
    const userId = getUserIdFromReq(req);
    const deviceId = userId || String(req.headers['x-device-id'] || '').trim();
    if (!deviceId) return sendJson(res, 400, { error: 'MissingIdentity' });
    const today = new Date().toISOString().substring(0, 10);
    const obj = _readPointsData(deviceId);
    const done = obj && obj.lastCheckinDate === today;
    const streak = (obj && obj.checkinStreak) || 0;
    return sendJson(res, 200, { checkedInToday: !!done, streak });
  }

  // POST /checkin — Server-side daily checkin
  if (req.method === 'POST' && req.url === '/checkin') {
    if (!verifyApiKey(req)) return sendJson(res, 401, { error: 'Unauthorized' });
    const userId = getUserIdFromReq(req);
    const deviceId = userId || String(req.headers['x-device-id'] || '').trim();
    if (!deviceId) return sendJson(res, 400, { error: 'MissingIdentity', message: '请先登录' });
    const config = loadConfig();
    const result = await doCheckin({ deviceId, config });
    if (!result) return sendJson(res, 500, { error: 'CheckinFailed' });
    return sendJson(res, 200, result);
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
    // Record DAU for logged-in users
    const userId = getUserIdFromReq(req);
    if (userId) {
      const platform = String(req.headers['x-platform'] || '').trim();
      recordActivity({ userId, platform, action: 'api_call' });
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
