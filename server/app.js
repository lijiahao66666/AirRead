'use strict';

const http = require('http');
const https = require('https');
const crypto = require('crypto');
const fs = require('fs');
const path = require('path');

// --- 加载 .env 文件 ---
(function loadEnv() {
  const envPath = path.join(__dirname, '.env');
  if (!fs.existsSync(envPath)) return;
  const lines = fs.readFileSync(envPath, 'utf8').split('\n');
  for (const line of lines) {
    const trimmed = line.trim();
    if (!trimmed || trimmed.startsWith('#')) continue;
    const idx = trimmed.indexOf('=');
    if (idx <= 0) continue;
    const key = trimmed.slice(0, idx).trim();
    let val = trimmed.slice(idx + 1).trim();
    if ((val.startsWith('"') && val.endsWith('"')) || (val.startsWith("'") && val.endsWith("'"))) {
      val = val.slice(1, -1);
    }
    if (!process.env[key]) process.env[key] = val;
  }
})();

// --- 工具函数：API Key 校验 ---
function verifyApiKey(req) {
  const serverKey = (process.env.API_KEY || '').trim();
  if (!serverKey) return true; // 未配置 API_KEY 时默认放行（开发模式）
  const clientKey = String(req.headers['x-api-key'] || '').trim();
  return clientKey === serverKey;
}

/*
 * AirRead 统一后端服务（轻量云端版）
 *
 * 主要功能：
 * 1. 代理腾讯云 API 请求（混元 / TTS / TMT），并在服务端完成签名。
 * 2. 本地 JSON 积分计费。
 * 3. 提供 App 远程配置接口（/config）。
 *
 * 关键环境变量：
 * - TENCENT_SECRET_ID / TENCENT_SECRET_KEY：腾讯云签名凭据。
 * - API_KEY：可选，静态接口鉴权。
 * - PORT：可选，默认 9000。
 *
 * 本地数据目录：
 * - ./config.json：App 远程配置。
 * - ./data/points/{identity}.json：用户或设备积分数据。
 */

// --- 工具函数：加密相关 ---
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

// --- 工具函数：腾讯云 TC3 签名 ---
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

// --- 本地积分存储（已替代 COS） ---
const DATA_DIR = path.join(__dirname, 'data', 'points');
if (!fs.existsSync(DATA_DIR)) {
  fs.mkdirSync(DATA_DIR, { recursive: true });
}

// --- 用户认证存储目录 ---
const USERS_DIR = path.join(__dirname, 'data', 'users');
const SMS_DIR = path.join(__dirname, 'data', 'sms');
const TOKENS_DIR = path.join(__dirname, 'data', 'tokens');
const STATS_DIR = path.join(__dirname, 'data', 'stats', 'daily');
const STATS_ARCHIVE_DIR = path.join(__dirname, 'data', 'stats', 'archive');
[USERS_DIR, SMS_DIR, TOKENS_DIR, STATS_DIR, STATS_ARCHIVE_DIR].forEach(d => {
  if (!fs.existsSync(d)) fs.mkdirSync(d, { recursive: true });
});
const STATS_FLUSH_INTERVAL_MS = Math.max(1000, Number(process.env.STATS_FLUSH_INTERVAL_MS || 5000));
const STATS_RETENTION_DAYS = Math.max(7, Number(process.env.STATS_RETENTION_DAYS || 90));
const STATS_CLEANUP_INTERVAL_MS = Math.max(10 * 60 * 1000, Number(process.env.STATS_CLEANUP_INTERVAL_MS || (6 * 60 * 60 * 1000)));

// --- 短信能力：腾讯云 SMS API ---
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

  // 发送频率限制：同手机号 60 秒 1 次，每日最多 10 次
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
  const expireAt = now + 5 * 60 * 1000; // 验证码 5 分钟过期

  // 通过腾讯云 SMS API 发送验证码
  const smsAppId = (process.env.SMS_APP_ID || '').trim();
  const smsSign = (process.env.SMS_SIGN || '').trim();
  const smsTemplateId = (process.env.SMS_TEMPLATE_ID || '').trim();
  const secretId = (process.env.TENCENT_SECRET_ID || '').trim();
  const secretKey = (process.env.TENCENT_SECRET_KEY || '').trim();

  if (!smsAppId || !smsSign || !smsTemplateId || !secretId || !secretKey) {
    console.error('[SMS] Missing SMS config env vars');
    return { error: 'SmsConfigError', message: '短信服务未配置' };
  }

  // 模板参数：1=仅验证码{1}，2=验证码{1}+有效期分钟数{2}；需与腾讯云正文模板占位符一致
  const paramCount = parseInt((process.env.SMS_TEMPLATE_PARAM_COUNT || '1').trim(), 10) || 1;
  const templateParamSet = paramCount >= 2 ? [code, '5'] : [code];

  const smsPayload = {
    SmsSdkAppId: smsAppId,
    SignName: smsSign,
    TemplateId: smsTemplateId,
    TemplateParamSet: templateParamSet,
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

  // 持久化验证码记录
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
    // 验证码一次性使用，校验成功后立即删除
    fs.unlinkSync(file);
    return true;
  } catch (_) {
    return false;
  }
}

// --- 用户管理 ---
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
    // 回收旧 token
    if (user.token) {
      const oldTf = _tokenFile(user.token);
      try { if (fs.existsSync(oldTf)) fs.unlinkSync(oldTf); } catch (_) {}
    }
    // 颁发新 token
    const token = _generateToken();
    user.token = token;
    user.lastLoginAt = now;
    user.loginCount = (user.loginCount || 0) + 1;
    fs.writeFileSync(file, JSON.stringify(user, null, 2), 'utf-8');
    // 保存 token -> userId 的映射
    fs.writeFileSync(_tokenFile(token), JSON.stringify({ userId: user.userId, phone: safe }), 'utf-8');
    return user;
  }

  // 新注册用户
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
    // 二次校验 token 一致性（防止 token 文件残留导致脏读）
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

// --- 工具函数：从请求中提取 userId（token 认证） ---
function getUserIdFromReq(req) {
  const token = String(req.headers['x-auth-token'] || '').trim();
  if (!token) return null;
  const user = getUserByToken(token);
  return user ? user.userId : null;
}

// --- DAU（日活）统计 ---
function _statsFile(date) {
  return path.join(STATS_DIR, `${date}.json`);
}

let _statsCacheDate = null;
let _statsCache = null;
let _statsActiveUsers = new Set();
let _statsDirty = false;
let _statsFlushTimer = null;

function _todayDate() {
  return new Date().toISOString().substring(0, 10);
}

function _daysAgoDate(days) {
  const d = new Date();
  d.setUTCHours(0, 0, 0, 0);
  d.setUTCDate(d.getUTCDate() - days);
  return d.toISOString().substring(0, 10);
}

function _parseStatsFileName(name) {
  const m = /^(\d{4}-\d{2}-\d{2})\.json$/.exec(String(name || ''));
  if (!m) return null;
  return { date: m[1], yearMonth: m[1].substring(0, 7) };
}

function _archiveOldStatsFiles() {
  try {
    if (!fs.existsSync(STATS_DIR)) return;
    const cutoffDate = _daysAgoDate(STATS_RETENTION_DAYS);
    const entries = fs.readdirSync(STATS_DIR);
    let archived = 0;
    for (const name of entries) {
      const parsed = _parseStatsFileName(name);
      if (!parsed) continue;
      if (parsed.date >= cutoffDate) continue;
      const src = path.join(STATS_DIR, name);
      const monthDir = path.join(STATS_ARCHIVE_DIR, parsed.yearMonth);
      if (!fs.existsSync(monthDir)) fs.mkdirSync(monthDir, { recursive: true });
      const dst = path.join(monthDir, name);
      if (fs.existsSync(dst)) {
        try {
          fs.unlinkSync(src);
          archived++;
        } catch (_) {}
        continue;
      }
      fs.renameSync(src, dst);
      archived++;
    }
    if (archived > 0) {
      console.log(`[stats] archived ${archived} file(s), keepDays=${STATS_RETENTION_DAYS}`);
    }
  } catch (e) {
    console.error('[stats] archive failed:', e && e.message ? e.message : e);
  }
}

function _newStats(date) {
  return {
    date,
    activeUsers: [],
    dau: 0,
    newUsers: 0,
    platformBreakdown: {},
    totalApiCalls: 0,
    totalPointsUsed: 0,
  };
}

function _normalizeStats(date, raw) {
  if (!raw || typeof raw !== 'object') return _newStats(date);
  const safe = _newStats(date);
  if (typeof raw.date === 'string') safe.date = raw.date;
  if (Number.isFinite(Number(raw.newUsers))) safe.newUsers = Number(raw.newUsers);
  if (Number.isFinite(Number(raw.totalApiCalls))) safe.totalApiCalls = Number(raw.totalApiCalls);
  if (Number.isFinite(Number(raw.totalPointsUsed))) safe.totalPointsUsed = Number(raw.totalPointsUsed);
  if (Array.isArray(raw.activeUsers)) {
    const seen = new Set();
    for (const item of raw.activeUsers) {
      const uid = String(item || '').trim();
      if (!uid || seen.has(uid)) continue;
      seen.add(uid);
      safe.activeUsers.push(uid);
    }
  }
  safe.dau = safe.activeUsers.length;
  if (raw.platformBreakdown && typeof raw.platformBreakdown === 'object') {
    for (const key of Object.keys(raw.platformBreakdown)) {
      const n = Number(raw.platformBreakdown[key]);
      safe.platformBreakdown[key] = Number.isFinite(n) && n > 0 ? n : 0;
    }
  }
  return safe;
}

function _loadStats(date) {
  const file = _statsFile(date);
  try {
    if (!fs.existsSync(file)) return _newStats(date);
    const raw = JSON.parse(fs.readFileSync(file, 'utf-8'));
    return _normalizeStats(date, raw);
  } catch (_) {
    return _newStats(date);
  }
}

function _flushStatsSync() {
  if (!_statsDirty || !_statsCache || !_statsCacheDate) return;
  _statsCache.dau = _statsActiveUsers.size;
  const file = _statsFile(_statsCacheDate);
  try {
    fs.writeFileSync(file, JSON.stringify(_statsCache, null, 2), 'utf-8');
    _statsDirty = false;
  } catch (e) {
    console.error('[stats] flush failed:', e && e.message ? e.message : e);
  }
}

function _scheduleStatsFlush() {
  _statsDirty = true;
  if (_statsFlushTimer) return;
  _statsFlushTimer = setTimeout(() => {
    _statsFlushTimer = null;
    _flushStatsSync();
  }, STATS_FLUSH_INTERVAL_MS);
  if (_statsFlushTimer && typeof _statsFlushTimer.unref === 'function') {
    _statsFlushTimer.unref();
  }
}

function _ensureTodayStats() {
  const today = _todayDate();
  if (_statsCacheDate !== today || !_statsCache) {
    _flushStatsSync();
    _statsCacheDate = today;
    _statsCache = _loadStats(today);
    _statsActiveUsers = new Set(_statsCache.activeUsers);
    _statsCache.dau = _statsActiveUsers.size;
  }
  return _statsCache;
}

function recordActivity({ userId, platform, action }) {
  const uid = String(userId || '').trim();
  if (!uid) return;
  const stats = _ensureTodayStats();
  if (!_statsActiveUsers.has(uid)) {
    _statsActiveUsers.add(uid);
    stats.activeUsers.push(uid);
  }
  stats.dau = _statsActiveUsers.size;
  const platformKey = String(platform || '').trim();
  if (platformKey) {
    stats.platformBreakdown[platformKey] = (stats.platformBreakdown[platformKey] || 0) + 1;
  }
  if (action === 'api_call') {
    stats.totalApiCalls = (stats.totalApiCalls || 0) + 1;
  }
  _scheduleStatsFlush();
}

process.on('beforeExit', _flushStatsSync);
process.on('exit', _flushStatsSync);

function _runStatsMaintenance() {
  _flushStatsSync();
  _archiveOldStatsFiles();
}

_runStatsMaintenance();
const _statsCleanupTimer = setInterval(_runStatsMaintenance, STATS_CLEANUP_INTERVAL_MS);
if (_statsCleanupTimer && typeof _statsCleanupTimer.unref === 'function') {
  _statsCleanupTimer.unref();
}

function _pointsFile(deviceId) {
  // 清洗 deviceId，避免路径穿越
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

// 确保身份有积分记录；首次赠送仅对已登录 userId 生效
// 返回 { balance, initialGrantedThisTime }，供客户端决定是否展示首登赠送提示
async function ensureInitialGrant({ deviceId, config, isUserId }) {
  let obj = _readPointsData(deviceId);
  const grantAmount = Number(config.initial_grant_points) || 500000;
  if (!obj) {
    if (isUserId) {
      obj = { balance: grantAmount, initialGranted: true, createdAt: new Date().toISOString() };
      _writePointsData(deviceId, obj);
      console.log(`[points] initial grant ${grantAmount} to userId=${deviceId}`);
      return { balance: grantAmount, initialGrantedThisTime: true };
    } else {
      obj = { balance: 0, initialGranted: false, createdAt: new Date().toISOString() };
      _writePointsData(deviceId, obj);
      console.log(`[points] new anonymous device ${deviceId}, balance=0`);
      return { balance: 0, initialGrantedThisTime: false };
    }
  }
  if (!obj.initialGranted && isUserId) {
    obj.balance = (Number(obj.balance) || 0) + grantAmount;
    obj.initialGranted = true;
    _writePointsData(deviceId, obj);
    console.log(`[points] late initial grant ${grantAmount} to userId=${deviceId}, new balance=${obj.balance}`);
    return { balance: Number(obj.balance), initialGrantedThisTime: true };
  }
  return { balance: Number(obj.balance || 0), initialGrantedThisTime: false };
}

// 服务端执行签到：返回 { points, alreadyDone, balance }，失败返回 null
async function doCheckin({ deviceId, config }) {
  if (!deviceId) return null;
  const today = new Date().toISOString().substring(0, 10);
  let obj = _readPointsData(deviceId) || { balance: 0 };

  const lastCheckin = obj.lastCheckinDate || '';
  if (lastCheckin === today) {
    return { points: 0, alreadyDone: true, balance: obj.balance };
  }

  const reward = Number(config.checkin_points) || 5000;
  obj.balance = (Number(obj.balance) || 0) + reward;
  obj.lastCheckinDate = today;
  _writePointsData(deviceId, obj);
  console.log(`[checkin] ${deviceId} +${reward}`);
  return { points: reward, alreadyDone: false, balance: obj.balance };
}

// --- 工具函数：HTTP 读写 ---
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
  res.setHeader('Access-Control-Allow-Origin', '*'); // 所有响应统一放开 CORS
  res.setHeader('Content-Length', Buffer.byteLength(body));
  res.end(body);
}

// --- 核心逻辑：API 代理 ---
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

  // --- 安全校验：静态 API Key ---
  if (!usingPersonalKeys && !verifyApiKey(req)) {
    return sendJson(res, 401, { error: 'Unauthorized', message: 'Invalid or missing API key' });
  }

  // 积分记账优先使用已登录 userId，其次才使用 deviceId
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

// --- 远程配置 ---
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

// --- 主服务入口 ---
const server = http.createServer(async (req, res) => {
  // CORS 预检与跨域头
  res.setHeader('Access-Control-Allow-Origin', '*');
  res.setHeader('Access-Control-Allow-Headers', 'content-type,x-api-key,x-device-id,x-auth-token,x-platform,accept');
  res.setHeader('Access-Control-Allow-Methods', 'GET, POST, OPTIONS');

  if (req.method === 'OPTIONS') {
    res.writeHead(204);
    res.end();
    return;
  }

  // GET /config：下发 App 远程配置（支持 query，如 ?v=1）
  const pathOnly = (req.url || '').split('?')[0];
  if (req.method === 'GET' && pathOnly === '/config') {
    const config = loadConfig();
    res.writeHead(200, {
      'Content-Type': 'application/json; charset=utf-8',
      'Access-Control-Allow-Origin': '*',
    });
    res.end(JSON.stringify(config));
    return;
  }

  // GET / 或 /health：健康检查
  if (req.method === 'GET' && (pathOnly === '/' || pathOnly === '/health')) {
    res.writeHead(200, {
      'Content-Type': 'text/plain',
      'Access-Control-Allow-Origin': '*',
    });
    res.end('OK');
    return;
  }

  // === 认证接口 ===

  // POST /auth/sms/send：发送短信验证码
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

  // POST /auth/sms/verify：校验验证码并登录/注册
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

    // 确保用户账号执行首登赠送（幂等：只会赠送一次）
    const grantResult = await ensureInitialGrant({ deviceId: user.userId, config, isUserId: true });

    // 将设备匿名积分合并到 userId（累加），随后清零设备积分
    const deviceId = String(req.headers['x-device-id'] || '').trim();
    if (deviceId && deviceId !== user.userId) {
      const devicePoints = _readPointsData(deviceId);
      if (devicePoints && devicePoints.balance > 0) {
        const userPoints = _readPointsData(user.userId) || { balance: 0 };
        const merged = (Number(userPoints.balance) || 0) + (Number(devicePoints.balance) || 0);
        userPoints.balance = merged;
        userPoints.initialGranted = true;
        _writePointsData(user.userId, userPoints);
        // 合并后将设备积分清零
        devicePoints.balance = 0;
        _writePointsData(deviceId, devicePoints);
        console.log(`[Auth] Merged device ${deviceId} points (+${devicePoints.balance}) into user ${user.userId}, new balance=${merged}`);
      }
    }

    // 记录该账号关联过的设备
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
      initialGrantedThisTime: grantResult.initialGrantedThisTime,
      initialGrantPoints: grantResult.initialGrantedThisTime ? (Number(config.initial_grant_points) || 500000) : undefined,
    });
  }

  // POST /auth/profile：获取当前用户信息（需 token）
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

  // POST /auth/logout：退出登录（撤销 token，并清零当前设备积分）
  if (req.method === 'POST' && req.url === '/auth/logout') {
    const token = String(req.headers['x-auth-token'] || '').trim();
    const deviceId = String(req.headers['x-device-id'] || '').trim();
    if (token) revokeToken(token);
    // 退出时清零设备积分（账号积分保留）
    if (deviceId) {
      const deviceObj = _readPointsData(deviceId);
      if (deviceObj) {
        deviceObj.balance = 0;
        _writePointsData(deviceId, deviceObj);
        console.log(`[Auth] Reset device ${deviceId} points to 0 after logout`);
      }
    }
    return sendJson(res, 200, { success: true });
  }

  // POST /admin/points/lookup 或 /points/admin/lookup：按手机号查询账号积分（管理工具）
  if (
    req.method === 'POST' &&
    (pathOnly === '/admin/points/lookup' || pathOnly === '/points/admin/lookup')
  ) {
    if (!verifyApiKey(req)) return sendJson(res, 401, { error: 'Unauthorized' });
    let body;
    try { body = await readJsonBody(req); } catch (_) { return sendJson(res, 400, { error: 'InvalidJson' }); }

    const phone = String(body.phone || '').replace(/[^0-9]/g, '');
    if (phone.length !== 11) {
      return sendJson(res, 400, { error: 'InvalidPhone', message: '请输入正确的手机号' });
    }

    const userFile = _userFile(phone);
    if (!fs.existsSync(userFile)) {
      return sendJson(res, 404, { error: 'UserNotFound', message: '该手机号在此应用未找到登录账号' });
    }

    try {
      const user = JSON.parse(fs.readFileSync(userFile, 'utf-8'));
      const userId = String(user.userId || '').trim();
      if (!userId) {
        return sendJson(res, 500, { error: 'UserDataInvalid', message: '用户数据异常：缺少 userId' });
      }
      const balance = await getPointsBalance({ deviceId: userId });
      return sendJson(res, 200, {
        phone,
        userId,
        balance,
        createdAt: user.createdAt,
        lastLoginAt: user.lastLoginAt,
        loginCount: Number(user.loginCount || 0),
      });
    } catch (_) {
      return sendJson(res, 500, { error: 'UserDataInvalid', message: '用户数据读取失败' });
    }
  }

  // POST /admin/points/grant 或 /points/admin/grant：按手机号赠送账号积分（管理工具）
  if (
    req.method === 'POST' &&
    (pathOnly === '/admin/points/grant' || pathOnly === '/points/admin/grant')
  ) {
    if (!verifyApiKey(req)) return sendJson(res, 401, { error: 'Unauthorized' });
    let body;
    try { body = await readJsonBody(req); } catch (_) { return sendJson(res, 400, { error: 'InvalidJson' }); }

    const phone = String(body.phone || '').replace(/[^0-9]/g, '');
    if (phone.length !== 11) {
      return sendJson(res, 400, { error: 'InvalidPhone', message: '请输入正确的手机号' });
    }

    const points = Number(body.points);
    if (!Number.isInteger(points) || points <= 0) {
      return sendJson(res, 400, { error: 'InvalidPoints', message: 'points 必须是正整数' });
    }
    if (points > 1000000000) {
      return sendJson(res, 400, { error: 'InvalidPoints', message: '单次赠送积分不能超过 10 亿' });
    }

    const userFile = _userFile(phone);
    if (!fs.existsSync(userFile)) {
      return sendJson(res, 404, { error: 'UserNotFound', message: '该手机号在此应用未找到登录账号' });
    }

    try {
      const user = JSON.parse(fs.readFileSync(userFile, 'utf-8'));
      const userId = String(user.userId || '').trim();
      if (!userId) {
        return sendJson(res, 500, { error: 'UserDataInvalid', message: '用户数据异常：缺少 userId' });
      }

      const beforeBalance = await getPointsBalance({ deviceId: userId });
      const afterBalance = await setPointsBalance({ deviceId: userId, balance: beforeBalance + points });
      console.log(`[AdminPoints] grant +${points} to ${userId}, before=${beforeBalance}, after=${afterBalance}`);

      return sendJson(res, 200, {
        phone,
        userId,
        points,
        beforeBalance,
        afterBalance,
      });
    } catch (_) {
      return sendJson(res, 500, { error: 'UserDataInvalid', message: '用户数据读取失败' });
    }
  }
  // GET /stats/today：查询今日 DAU 统计（管理用）
  if (req.method === 'GET' && req.url === '/stats/today') {
    if (!verifyApiKey(req)) return sendJson(res, 401, { error: 'Unauthorized' });
    try {
      const stats = _ensureTodayStats();
      return sendJson(res, 200, stats);
    } catch (_) {
      return sendJson(res, 200, { date: _todayDate(), dau: 0, activeUsers: [], totalApiCalls: 0 });
    }
  }

  // === 积分与签到接口（优先 token 对应 userId，回退 deviceId） ===

  // POST /points/init：初始化积分并返回余额（首登赠送仅登录 userId 可得）
  if (req.method === 'POST' && req.url === '/points/init') {
    if (!verifyApiKey(req)) return sendJson(res, 401, { error: 'Unauthorized' });
    const userId = getUserIdFromReq(req);
    const deviceId = userId || String(req.headers['x-device-id'] || '').trim();
    if (!deviceId) return sendJson(res, 400, { error: 'MissingIdentity', message: '缺少设备标识' });
    const config = loadConfig();
    const { balance } = await ensureInitialGrant({ deviceId, config, isUserId: !!userId });
    return sendJson(res, 200, { balance });
  }

  // POST /points/balance：查询当前积分余额
  if (req.method === 'POST' && req.url === '/points/balance') {
    if (!verifyApiKey(req)) return sendJson(res, 401, { error: 'Unauthorized' });
    const userId = getUserIdFromReq(req);
    const deviceId = userId || String(req.headers['x-device-id'] || '').trim();
    if (!deviceId) return sendJson(res, 400, { error: 'MissingIdentity' });
    const balance = await getPointsBalance({ deviceId });
    return sendJson(res, 200, { balance });
  }

  // POST /checkin/status：查询今日是否已签到
  if (req.method === 'POST' && req.url === '/checkin/status') {
    if (!verifyApiKey(req)) return sendJson(res, 401, { error: 'Unauthorized' });
    const userId = getUserIdFromReq(req);
    const deviceId = userId || String(req.headers['x-device-id'] || '').trim();
    if (!deviceId) return sendJson(res, 400, { error: 'MissingIdentity' });
    const today = new Date().toISOString().substring(0, 10);
    const obj = _readPointsData(deviceId);
    const done = obj && obj.lastCheckinDate === today;
    return sendJson(res, 200, { checkedInToday: !!done });
  }

  // POST /checkin：执行服务端每日签到
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

  // POST /：统一 API 代理入口
  if (req.method === 'POST') {
    let body;
    try {
      body = await readJsonBody(req);
    } catch (e) {
      sendJson(res, 400, { error: 'InvalidJson', message: String(e && e.message ? e.message : e) });
      return;
    }
    // 已登录用户调用代理接口时记录 DAU 行为
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
