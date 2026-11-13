// LLM 内置代理（OpenAI 兼容 /chat/completions，按 token 扣积分）
//
// 支持：
//  - 普通响应
//  - SSE 流式响应（含 reasoning_content 思考过程透传）
//  - tools / tool_choice 透传（Agent 工具调用）
//  - 按上游 usage 扣积分；无 usage 时按字符数估算
//  - 同一模型配置多组 BaseURL / APIKey，按健康状态智能路由与自动重试
//  - apiBase 可填到 /v1（自动补 /chat/completions），也可直接填完整地址

import {
  MIN_CALL_CREDITS,
  TOKENS_PER_CREDIT,
} from '../config.js';
import { bumpStat, getDb, saveDb } from '../db.js';
import { CORS_HEADERS, readJson, sendJson } from '../http.js';
import { requireUser } from '../security.js';
import { applyCredits, getCredits } from './me.js';

function modelDefaults(m) {
  const multiplier = Number.isFinite(m.multiplier) ? m.multiplier : 1;
  return {
    multiplier,
    tokensPerCredit: Math.round(TOKENS_PER_CREDIT / multiplier),
  };
}

function publicLlmModel(m) {
  const d = modelDefaults(m);
  return {
    id: m.id,
    name: m.name,
    description: m.description || '',
    multiplier: d.multiplier,
    tokensPerCredit: d.tokensPerCredit,
    supportsVision: m.supportsVision === true,
    isDefault: false,
  };
}

/** 把 apiBase 解析为完整的 chat/completions 地址 */
export function resolveChatUrl(apiBase) {
  const base = String(apiBase || '').trim().replace(/\/+$/, '');
  if (!base) return '';
  if (/\/chat\/completions$/i.test(base)) return base;
  if (/\/completions$/i.test(base)) return base;
  return `${base}/chat/completions`;
}

/** 模型可用于调用的线路（兼容旧的单 apiBase 配置） */
function modelChannels(config) {
  const list = Array.isArray(config.channels)
    ? config.channels.filter(
        (c) => c && c.enabled !== false && resolveChatUrl(c.apiBase),
      )
    : [];
  if (list.length > 0) {
    return list.map((c, index) => ({
      id: String(c.id || `ch_${index}`),
      name: String(c.name || `线路 ${index + 1}`),
      apiBase: String(c.apiBase),
      apiKey: String(c.apiKey || ''),
      weight: Number.isFinite(c.weight) ? Math.max(1, c.weight) : 1,
    }));
  }
  if (resolveChatUrl(config.apiBase)) {
    return [
      {
        id: 'default',
        name: '默认线路',
        apiBase: String(config.apiBase),
        apiKey: String(config.apiKey || ''),
        weight: 1,
      },
    ];
  }
  return [];
}

// 线路健康状态（内存态，重启后重置）：失败冷却 + 最近使用时间
const channelHealth = new Map();

function healthKey(modelId, channelId) {
  return `${modelId}::${channelId}`;
}

function channelState(modelId, channelId) {
  const key = healthKey(modelId, channelId);
  if (!channelHealth.has(key)) {
    channelHealth.set(key, {
      fails: 0,
      cooldownUntil: 0,
      lastUsedAt: 0,
      lastError: '',
    });
  }
  return channelHealth.get(key);
}

/** 智能路由：优先未冷却、失败少、最近最少使用的线路 */
function orderedChannels(config) {
  const now = Date.now();
  return modelChannels(config)
    .map((channel) => ({ channel, state: channelState(config.id, channel.id) }))
    .filter(({ state }) => state.cooldownUntil <= now)
    .sort(
      (a, b) =>
        a.state.fails - b.state.fails ||
        a.state.lastUsedAt - b.state.lastUsedAt ||
        a.channel.weight - b.channel.weight,
    )
    .map(({ channel }) => channel);
}

function markChannelSuccess(config, channel, latencyMs) {
  const state = channelState(config.id, channel.id);
  state.fails = 0;
  state.cooldownUntil = 0;
  state.lastUsedAt = Date.now();
  state.latencyMs = latencyMs;
}

function markChannelFailure(config, channel, error) {
  const state = channelState(config.id, channel.id);
  state.fails += 1;
  state.lastUsedAt = Date.now();
  state.lastError = String(error || '').slice(0, 200);
  // 指数退避冷却：30s / 60s / 120s，最长 5 分钟
  const cooldown = Math.min(300_000, 30_000 * 2 ** (state.fails - 1));
  state.cooldownUntil = Date.now() + cooldown;
  recordChannelStat(config, channel, { ok: false, error: state.lastError });
}

/** 按模型 / 线路维度累计调用统计 */
function recordChannelStat(config, channel, { ok, tokens = 0, error = '' }) {
  const db = getDb();
  if (!db.stats.models || typeof db.stats.models !== 'object') {
    db.stats.models = {};
  }
  if (!db.stats.channels || typeof db.stats.channels !== 'object') {
    db.stats.channels = {};
  }
  const modelStat = db.stats.models[config.id] || {
    name: config.name,
    calls: 0,
    tokens: 0,
    errors: 0,
    lastAt: 0,
  };
  const channelKey = healthKey(config.id, channel.id);
  const channelStat = db.stats.channels[channelKey] || {
    modelId: config.id,
    modelName: config.name,
    channelId: channel.id,
    channelName: channel.name,
    calls: 0,
    tokens: 0,
    errors: 0,
    lastAt: 0,
    lastError: '',
  };
  modelStat.name = config.name;
  channelStat.channelName = channel.name;
  modelStat.lastAt = Date.now();
  channelStat.lastAt = Date.now();
  if (ok) {
    modelStat.calls += 1;
    modelStat.tokens += tokens;
    channelStat.calls += 1;
    channelStat.tokens += tokens;
  } else {
    modelStat.errors += 1;
    channelStat.errors += 1;
    channelStat.lastError = error;
  }
  db.stats.models[config.id] = modelStat;
  db.stats.channels[channelKey] = channelStat;
}

// 并发预留：余额校验发生在请求开始，实际扣费在响应结束后；
// 若不做预留，并发请求或超大 prompt 请求会共用同一次余额校验结果，
// 配合 applyCredits 的「不低于 0」钳制，可绕过计费（上游成本由服务方承担）。
// 因此按 prompt 侧预估成本预留，结算时释放。
const inflightReserved = new Map(); // userId -> 已预留积分数

function reserveInflight(userId, amount) {
  inflightReserved.set(userId, (inflightReserved.get(userId) || 0) + amount);
}

function releaseInflight(userId, amount) {
  const next = (inflightReserved.get(userId) || 0) - amount;
  if (next > 0) inflightReserved.set(userId, next);
  else inflightReserved.delete(userId);
}

/** 供测试观察内部预留状态 */
export function inflightReservedFor(userId) {
  return inflightReserved.get(userId) || 0;
}

/** 结算时统一释放预留并返回响应 */
async function withInflightRelease(user, reserved, respond) {
  try {
    await respond();
  } finally {
    releaseInflight(user.id, reserved);
  }
}

/** 判断消息中是否包含图片（多模态 content 数组） */
function messagesContainImage(messages) {
  for (const m of messages || []) {
    if (!Array.isArray(m?.content)) continue;
    for (const part of m.content) {
      if (part && part.type === 'image_url') return true;
    }
  }
  return false;
}

export async function handleLlmModels(req, res) {
  requireUser(req);
  const models = getDb()
    .llmModels.map(publicLlmModel)
    // 倍率越低越便宜，默认展示最便宜（DeepSeek Flash 0.2）
    .sort((a, b) => a.multiplier - b.multiplier);
  if (models.length) models[0].isDefault = true;
  sendJson(res, 200, {
    models,
    defaultModelId: models[0]?.id || '',
    tokensPerCredit: TOKENS_PER_CREDIT,
  });
}

/** 上游没有返回 usage 时按字符数粗略估算 token（中文约 1.5 字符/token，取 2） */
function estimatePromptTokens(messages) {
  let chars = 0;
  for (const m of messages || []) {
    if (typeof m?.content === 'string') chars += m.content.length;
    else chars += JSON.stringify(m?.content ?? '').length;
    if (Array.isArray(m?.tool_calls)) chars += JSON.stringify(m.tool_calls).length;
  }
  return Math.ceil(chars / 2);
}

function estimateTokens(messages, data) {
  const prompt = estimatePromptTokens(messages);
  let completion = 0;
  if (Array.isArray(data?.choices)) {
    for (const c of data.choices) {
      const msg = c?.message || {};
      if (typeof msg.content === 'string') completion += msg.content.length;
      if (typeof msg.reasoning_content === 'string') {
        completion += msg.reasoning_content.length;
      }
      if (Array.isArray(msg.tool_calls)) {
        completion += JSON.stringify(msg.tool_calls).length;
      }
    }
  }
  return prompt + Math.ceil(completion / 2);
}

function costForTokens(tokens, multiplier) {
  return Math.max(
    MIN_CALL_CREDITS,
    Math.ceil((Math.max(1, tokens) / TOKENS_PER_CREDIT) * multiplier),
  );
}

async function fetchUpstream(channel, upstreamBody, signal) {
  const url = resolveChatUrl(channel.apiBase);
  const send = (body) =>
    fetch(url, {
      method: 'POST',
      headers: {
        'Content-Type': 'application/json',
        Authorization: `Bearer ${channel.apiKey}`,
      },
      body: JSON.stringify(body),
      signal,
    });

  let upstream = await send(upstreamBody);
  // 部分上游不认 stream_options，去掉后重试一次
  if (
    upstreamBody.stream_options &&
    !upstream.ok &&
    (upstream.status === 400 || upstream.status === 422)
  ) {
    const clone = { ...upstreamBody };
    delete clone.stream_options;
    upstream = await send(clone);
  }
  return upstream;
}

/**
 * 按线路健康状态依次尝试（最多 3 条）。
 * 仅对网络错误 / 429 / 5xx 切换线路；4xx 参数错误直接返回给客户端。
 */
async function requestWithFailover(config, upstreamBody, signal) {
  const channels = orderedChannels(config);
  if (channels.length === 0) {
    throw new Error('模型未配置可用的 BaseURL / APIKey');
  }
  let lastError = null;
  for (const channel of channels.slice(0, 3)) {
    const startedAt = Date.now();
    try {
      const upstream = await fetchUpstream(channel, upstreamBody, signal);
      if (upstream.status === 429 || upstream.status >= 500) {
        lastError = new Error(`上游 HTTP ${upstream.status}`);
        markChannelFailure(config, channel, lastError.message);
        try {
          await upstream.body?.cancel();
        } catch {
          // 忽略取消失败
        }
        continue;
      }
      markChannelSuccess(config, channel, Date.now() - startedAt);
      return { upstream, channel };
    } catch (err) {
      if (err?.name === 'AbortError' || err?.name === 'TimeoutError') throw err;
      lastError = err;
      markChannelFailure(config, channel, err);
    }
  }
  throw lastError || new Error('所有线路均不可用');
}

export async function handleLlmChat(req, res) {
  const user = requireUser(req);
  const body = await readJson(req);
  const modelId = String(body.model || '');
  const config = getDb().llmModels.find((m) => m.id === modelId);
  if (!config) return sendJson(res, 400, { error: '模型不存在或已下线' });
  if (!Array.isArray(body.messages) || body.messages.length === 0) {
    return sendJson(res, 400, { error: 'messages 不能为空' });
  }
  // 图片理解需在后台为模型勾选「支持图片理解」
  if (messagesContainImage(body.messages) && config.supportsVision !== true) {
    return sendJson(res, 400, {
      error: '该模型未开启图片理解，请在后台为模型勾选「支持图片理解」',
    });
  }

  const { multiplier } = modelDefaults(config);
  // 预留 prompt 侧预估成本后再放行，防止并发/大 prompt 请求绕过计费
  const reserved = costForTokens(estimatePromptTokens(body.messages), multiplier);
  const balance = getCredits(user);
  if (balance - inflightReservedFor(user.id) < reserved) {
    return sendJson(res, 402, { error: '积分不足，请先充值', credits: balance });
  }
  reserveInflight(user.id, reserved);

  const upstreamBody = {
    model: config.model,
    messages: body.messages,
  };
  if (body.temperature !== undefined) upstreamBody.temperature = body.temperature;
  if (Array.isArray(body.tools) && body.tools.length > 0) {
    upstreamBody.tools = body.tools;
    if (body.tool_choice !== undefined) upstreamBody.tool_choice = body.tool_choice;
  }

  const wantStream = body.stream === true;
  if (wantStream) {
    upstreamBody.stream = true;
    upstreamBody.stream_options = { include_usage: true };
  }

  let upstream;
  let channel;
  try {
    const picked = await requestWithFailover(
      config,
      upstreamBody,
      AbortSignal.timeout(wantStream ? 300_000 : 120_000),
    );
    upstream = picked.upstream;
    channel = picked.channel;
  } catch (err) {
    releaseInflight(user.id, reserved);
    return sendJson(res, 502, {
      error: '无法连接上游模型服务',
      detail: String(err?.message || err).slice(0, 200),
    });
  }

  if (!upstream.ok) {
    let detail = '';
    try {
      detail = (await upstream.text()).slice(0, 300);
    } catch {
      detail = '';
    }
    markChannelFailure(config, channel, `HTTP ${upstream.status}: ${detail}`);
    await saveDb();
    releaseInflight(user.id, reserved);
    return sendJson(res, 502, {
      error: '上游模型调用失败',
      upstreamStatus: upstream.status,
      detail,
    });
  }

  if (wantStream) {
    return withInflightRelease(user, reserved, () =>
      proxyStream({
        req,
        res,
        user,
        config,
        channel,
        upstream,
        multiplier,
        messages: body.messages,
      }),
    );
  }
  return withInflightRelease(user, reserved, () =>
    proxyJson({
      res,
      user,
      config,
      channel,
      upstream,
      multiplier,
      messages: body.messages,
    }),
  );
}

// ---------------------------------------------------------------------------
// 普通响应
// ---------------------------------------------------------------------------

async function proxyJson({ res, user, config, channel, upstream, multiplier, messages }) {
  let text;
  try {
    text = await upstream.text();
  } catch {
    return sendJson(res, 502, { error: '读取上游响应失败' });
  }

  let data;
  try {
    data = JSON.parse(text);
  } catch {
    data = null;
  }
  if (!data) {
    return sendJson(res, 502, {
      error: '上游返回了非 JSON 响应',
      detail: text.slice(0, 300),
    });
  }

  const totalTokens =
    data.usage && Number.isFinite(data.usage.total_tokens)
      ? data.usage.total_tokens
      : estimateTokens(messages, data);
  const cost = costForTokens(totalTokens, multiplier);
  applyCredits(user, -cost, 'llm_usage', `${config.name} · ${totalTokens} tokens`);
  recordChannelStat(config, channel, { ok: true, tokens: totalTokens });
  bumpStat('llmCalls');
  bumpStat('tokensUsed', totalTokens);
  await saveDb();

  data._credits = { used: cost, remaining: getCredits(user), totalTokens };
  sendJson(res, 200, data);
}

// ---------------------------------------------------------------------------
// SSE 流式响应
// ---------------------------------------------------------------------------

async function proxyStream({
  req,
  res,
  user,
  config,
  channel,
  upstream,
  multiplier,
  messages,
}) {
  res.writeHead(200, {
    'Content-Type': 'text/event-stream; charset=utf-8',
    'Cache-Control': 'no-cache, no-transform',
    Connection: 'keep-alive',
    // 关键：告诉 Nginx 不要缓冲，保证思考过程实时到达客户端
    'X-Accel-Buffering': 'no',
    ...CORS_HEADERS,
  });
  if (typeof res.flushHeaders === 'function') res.flushHeaders();

  let clientClosed = false;
  req.on('close', () => {
    clientClosed = true;
  });

  const decoder = new TextDecoder();
  let buffer = '';
  let usage = null;
  let contentChars = 0;
  let reasoningChars = 0;
  let toolChars = 0;

  const write = (chunk) => {
    if (clientClosed || res.writableEnded) return;
    res.write(chunk);
  };

  const consumeLine = (line) => {
    const trimmed = line.trim();
    if (!trimmed.startsWith('data:')) {
      // 注释 / event: 行原样转发
      return { forward: `${line}\n`, done: false };
    }
    const payload = trimmed.slice(5).trim();
    if (payload === '[DONE]') return { forward: '', done: true };
    let data;
    try {
      data = JSON.parse(payload);
    } catch {
      return { forward: `${line}\n`, done: false };
    }
    if (data.usage && Number.isFinite(data.usage.total_tokens)) {
      usage = data.usage;
    }
    const delta = data.choices?.[0]?.delta || {};
    if (typeof delta.content === 'string') contentChars += delta.content.length;
    const reasoning = delta.reasoning_content ?? delta.reasoning;
    if (typeof reasoning === 'string') reasoningChars += reasoning.length;
    if (Array.isArray(delta.tool_calls)) {
      toolChars += JSON.stringify(delta.tool_calls).length;
    }
    return { forward: `${line}\n`, done: false };
  };

  try {
    const reader = upstream.body.getReader();
    for (;;) {
      const { value, done } = await reader.read();
      if (done) break;
      buffer += decoder.decode(value, { stream: true });
      let newlineIndex;
      while ((newlineIndex = buffer.indexOf('\n')) >= 0) {
        const line = buffer.slice(0, newlineIndex).replace(/\r$/, '');
        buffer = buffer.slice(newlineIndex + 1);
        const result = consumeLine(line);
        if (result.forward) write(result.forward);
      }
    }
    if (buffer) {
      const result = consumeLine(buffer);
      if (result.forward) write(result.forward);
    }
  } catch (err) {
    write(
      `data: ${JSON.stringify({
        choices: [],
        _slipe: { error: '模型响应中断', detail: String(err?.message || err) },
      })}\n\n`,
    );
  }

  // 结算积分：优先使用上游 usage，否则按字符估算
  const promptTokens = estimatePromptTokens(messages);
  const completionTokens = Math.ceil((contentChars + reasoningChars + toolChars) / 2);
  const totalTokens =
    usage && Number.isFinite(usage.total_tokens)
      ? usage.total_tokens
      : promptTokens + completionTokens;
  const cost = costForTokens(totalTokens, multiplier);
  applyCredits(user, -cost, 'llm_usage', `${config.name} · ${totalTokens} tokens`);
  recordChannelStat(config, channel, { ok: true, tokens: totalTokens });
  bumpStat('llmCalls');
  bumpStat('tokensUsed', totalTokens);
  await saveDb();

  write(
    `data: ${JSON.stringify({
      choices: [],
      _slipe: {
        credits: { used: cost, remaining: getCredits(user), totalTokens },
      },
    })}\n\n`,
  );
  write('data: [DONE]\n\n');
  if (!clientClosed) res.end();
}
