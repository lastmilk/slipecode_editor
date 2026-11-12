// 联网搜索代理：使用后端已配置的 DeepSeek 线路调用官方 Search API
// 客户端只携带账号 token，不暴露上游 API Key。

import { getDb } from '../db.js';
import { readJson, sendJson } from '../http.js';
import { requireUser } from '../security.js';

function resolveSearchUrl(apiBase) {
  const base = String(apiBase || '').trim().replace(/\/+$/, '');
  if (!base) return '';
  if (/\/chat\/completions$/i.test(base)) {
    return base.replace(/\/chat\/completions$/i, '/tools/search');
  }
  if (/\/completions$/i.test(base)) {
    return base.replace(/\/completions$/i, '/tools/search');
  }
  if (/\/v1$/i.test(base)) return `${base}/tools/search`;
  return `${base}/v1/tools/search`;
}

/** 从模型线路中挑选可用的 DeepSeek 通道（Search API 仅 DeepSeek 提供） */
function pickDeepseekChannel() {
  const db = getDb();
  const models = Array.isArray(db.llmModels) ? db.llmModels : [];
  for (const model of models) {
    const channels = Array.isArray(model.channels)
      ? model.channels.filter((c) => c && c.enabled !== false)
      : [];
    for (const channel of channels) {
      if (/deepseek\.com/i.test(String(channel.apiBase || '')) && channel.apiKey) {
        return channel;
      }
    }
    if (/deepseek\.com/i.test(String(model.apiBase || '')) && model.apiKey) {
      return { apiBase: model.apiBase, apiKey: model.apiKey };
    }
  }
  return null;
}

export async function handleAiSearch(req, res) {
  requireUser(req);
  const body = await readJson(req);
  const query = String(body.query || '').trim();
  if (!query || query.length > 128) {
    return sendJson(res, 400, { error: 'query 不能为空且不超过 128 字符' });
  }
  const count = Math.min(10, Math.max(1, Number(body.count) || 5));
  const channel = pickDeepseekChannel();
  if (!channel) {
    return sendJson(res, 400, {
      error: '后端未配置 DeepSeek 线路，无法联网搜索',
    });
  }
  const url = resolveSearchUrl(channel.apiBase);
  let response;
  try {
    response = await fetch(url, {
      method: 'POST',
      headers: {
        'Content-Type': 'application/json',
        Authorization: `Bearer ${channel.apiKey}`,
      },
      body: JSON.stringify({ query, count, need_content: false }),
    });
  } catch (err) {
    return sendJson(res, 502, { error: `搜索请求失败：${err.message || err}` });
  }
  if (!response.ok) {
    let detail = '';
    try {
      const data = await response.json();
      detail = data?.error?.message || data?.error?.code || '';
    } catch (_) {
      // 忽略解析失败
    }
    return sendJson(res, 502, {
      error: `搜索服务返回 HTTP ${response.statusCode}${detail ? `：${detail}` : ''}`,
    });
  }
  const data = await response.json();
  const results = (Array.isArray(data.results) ? data.results : []).map((item) => ({
    title: item?.title || '',
    url: item?.url || '',
    summary: item?.summary || item?.snippet || '',
  }));
  sendJson(res, 200, { results });
}
