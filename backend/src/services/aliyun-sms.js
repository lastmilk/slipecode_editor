// 阿里云号码认证服务（DyPnsApi 2017-05-25）短信验证码
//
// 零依赖实现 V1 RPC 签名（HMAC-SHA1）。
// 未配置 AccessKey 时进入开发模式：发送接口返回固定验证码 123456。

import { createHmac, randomBytes } from 'node:crypto';

import { aliyunConfig, HTTP_TIMEOUT_MS } from '../config.js';
import { bumpStat, saveDb } from '../db.js';
import { httpError } from '../http.js';

function percentEncode(value) {
  return encodeURIComponent(String(value)).replace(
    /[!'()*]/g,
    (ch) => `%${ch.charCodeAt(0).toString(16).toUpperCase()}`,
  );
}

async function aliyunRpc(action, params) {
  const cfg = aliyunConfig();
  const common = {
    AccessKeyId: cfg.accessKeyId,
    Action: action,
    Format: 'JSON',
    RegionId: cfg.region,
    SignatureMethod: 'HMAC-SHA1',
    SignatureNonce: randomBytes(16).toString('hex'),
    SignatureVersion: '1.0',
    Timestamp: new Date().toISOString().replace(/\.\d{3}Z$/, 'Z'),
    Version: '2017-05-25',
    ...params,
  };
  const sorted = Object.keys(common)
    .sort()
    .map((key) => `${percentEncode(key)}=${percentEncode(common[key])}`)
    .join('&');
  const stringToSign = `GET&${percentEncode('/')}&${percentEncode(sorted)}`;
  const signature = createHmac('sha1', `${cfg.accessKeySecret}&`)
    .update(stringToSign)
    .digest('base64');
  const url = `https://${cfg.endpoint}/?${sorted}&Signature=${percentEncode(signature)}`;

  const res = await fetch(url, { signal: AbortSignal.timeout(HTTP_TIMEOUT_MS) });
  const text = await res.text();
  let data;
  try {
    data = JSON.parse(text);
  } catch {
    throw httpError(502, '短信服务响应异常');
  }
  if (!res.ok || data.Code) {
    throw httpError(502, data.Message || '短信服务调用失败');
  }
  return data;
}

/** 发送短信验证码（阿里云自行生成并下发验证码） */
async function sendSmsVerifyCode(phone) {
  const cfg = aliyunConfig();
  return aliyunRpc('SendSmsVerifyCode', {
    PhoneNumber: phone,
    SignName: cfg.signName,
    TemplateCode: cfg.templateCode,
    TemplateParam: JSON.stringify({ code: '', min: cfg.validMinutes }),
    CodeLength: 6,
    ValidTime: cfg.validMinutes * 60,
  });
}

export async function checkSmsVerifyCode(phone, code) {
  const cfg = aliyunConfig();
  if (cfg.devMode) return String(code) === '123456';
  const data = await aliyunRpc('CheckSmsVerifyCode', {
    PhoneNumber: phone,
    VerifyCode: code,
  });
  return data?.Model?.VerifyResult === 'PASS';
}

// ---------------------------------------------------------------------------
// 发送节流：同一手机号 60s 一次、每天上限 N 次
// ---------------------------------------------------------------------------

const smsSends = new Map();

function todayKey() {
  const d = new Date();
  return `${d.getFullYear()}-${String(d.getMonth() + 1).padStart(2, '0')}-${String(
    d.getDate(),
  ).padStart(2, '0')}`;
}

export function throttleSms(phone) {
  const cfg = aliyunConfig();
  const now = Date.now();
  const today = todayKey();
  const item = smsSends.get(phone);
  if (item && now - item.last < 60 * 1000) {
    throw httpError(429, '验证码发送过于频繁，请稍后再试');
  }
  if (item && item.day === today && item.count >= cfg.dailyLimit) {
    throw httpError(429, '今日验证码发送次数已达上限');
  }
  smsSends.set(phone, {
    last: now,
    day: today,
    count: item && item.day === today ? item.count + 1 : 1,
  });
}

export function isDevMode() {
  return aliyunConfig().devMode;
}

export function devCode() {
  return '123456';
}

/** 发送验证码（开发模式直接返回，不调用阿里云） */
export async function sendCode(phone) {
  const cfg = aliyunConfig();
  bumpStat('smsSent');
  await saveDb();
  if (cfg.devMode) return { dev: true };
  await sendSmsVerifyCode(phone);
  return { dev: false };
}
