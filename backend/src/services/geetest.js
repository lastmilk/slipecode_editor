// 极验验证码（GT4）服务端二次校验
//
// 客户端 SDK 返回 lot_number / captcha_output / pass_token / gen_time，
// 服务端用 captchaKey 做 HMAC-SHA256 计算 sign_token 后提交极验校验接口。

import { createHmac } from 'node:crypto';

import { bumpStat, saveDb } from '../db.js';
import { geetestConfig } from '../config.js';

/**
 * 校验客户端提交的极验结果。
 * @param {{lot_number:string, captcha_output:string, pass_token:string, gen_time:string}} captcha
 * @returns {Promise<boolean>}
 */
export async function verifyGeetest(captcha) {
  if (!captcha || typeof captcha !== 'object') return false;
  const lotNumber = String(captcha.lot_number || '');
  const captchaOutput = String(captcha.captcha_output || '');
  const passToken = String(captcha.pass_token || '');
  const genTime = String(captcha.gen_time || '');
  if (!lotNumber || !captchaOutput || !passToken || !genTime) return false;

  const { captchaId, captchaKey } = geetestConfig();
  if (!captchaId || !captchaKey) {
    console.warn('[geetest] 服务端未配置 captchaId / captchaKey，跳过校验');
    return true;
  }

  const signToken = createHmac('sha256', captchaKey).update(lotNumber).digest('hex');
  const form = new URLSearchParams({
    lot_number: lotNumber,
    captcha_output: captchaOutput,
    pass_token: passToken,
    gen_time: genTime,
    sign_token: signToken,
  });

  try {
    const res = await fetch(
      `https://gcaptcha4.geetest.com/validate?captcha_id=${encodeURIComponent(captchaId)}`,
      {
        method: 'POST',
        headers: { 'Content-Type': 'application/x-www-form-urlencoded' },
        body: form,
        signal: AbortSignal.timeout(6000),
      },
    );
    const data = await res.json().catch(() => null);
    const ok = Boolean(data && data.result === 'success');
    bumpStat(ok ? 'captchaPass' : 'captchaFail');
    await saveDb();
    if (!ok) console.warn('[geetest] 校验未通过：', data?.reason || data?.result);
    return ok;
  } catch (err) {
    bumpStat('captchaFail');
    await saveDb();
    console.warn('[geetest] 校验请求失败：', err.message);
    return false;
  }
}

/**
 * 注册/登录统一的人机验证拦截。
 * 非 Android 平台（客户端声明 unsupported）在强制模式下放行。
 */
export async function requireCaptchaIfNeeded(body) {
  const { enforce } = geetestConfig();
  if (!enforce) return true;
  if (body.captchaPlatform === 'unsupported') {
    console.warn('[geetest] 客户端平台不支持验证码，已放行');
    return true;
  }
  return verifyGeetest(body.captcha);
}
