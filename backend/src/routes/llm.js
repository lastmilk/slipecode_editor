// LLM 内置代理（OpenAI 兼容 /chat/completions，按 token 扣积分）
//
// 支持：
//  - 普通响应
//  - SSE 流式响应（含 reasoning_content 思考过程透传）
//  - tools / tool_choice 透传（Agent 工具调用）
//  - 按上游 usage 扣积分；无 usage 时按字符数估算

import {
  MIN_CALL_CREDITS,
  MIN_BALANCE_FOR_CALL,
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
    isDefault: false,
  };
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

async function fetchUpstream(config, upstreamBody, signal) {
  const url = `${String(config.apiBase).replace(/\/+$/, '')}/chat/completions`;
  const send = (body) =>
    fetch(url, {
      method: 'POST',
      headers: {
        'Content-Type': 'application/json',
        Authorization: `Bearer ${config.apiKey}`,
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

export async function handleLlmChat(req, res) {
  const user = requireUser(req);
  const body = await readJson(req);
  const modelId = String(body.model || '');
  const config = getDb().llmModels.find((m) => m.id === modelId);
  if (!config) return sendJson(res, 400, { error: '模型不存在或已下线' });
  if (!Array.isArray(body.messages) || body.messages.length === 0) {
    return sendJson(res, 400, { error: 'messages 不能为空' });
  }

  const balance = getCredits(user);
  if (balance < MIN_BALANCE_FOR_CALL) {
    return sendJson(res, 402, { error: '积分不足，请先充值', credits: balance });
  }

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

  const { multiplier } = modelDefaults(config);

  let upstream;
  try {
    upstream = await fetchUpstream(
      config,
      upstreamBody,
      AbortSignal.timeout(wantStream ? 300_000 : 120_000),
    );
  } catch {
    return sendJson(res, 502, { error: '无法连接上游模型服务' });
  }

  if (!upstream.ok) {
    let detail = '';
    try {
      detail = (await upstream.text()).slice(0, 300);
    } catch {
      detail = '';
    }
    return sendJson(res, 502, {
      error: '上游模型调用失败',
      upstreamStatus: upstream.status,
      detail,
    });
  }

  if (wantStream) {
    return proxyStream({ req, res, user, config, upstream, multiplier, messages: body.messages });
  }
  return proxyJson({ res, user, config, upstream, multiplier, messages: body.messages });
}

// ---------------------------------------------------------------------------
// 普通响应
// ---------------------------------------------------------------------------

async function proxyJson({ res, user, config, upstream, multiplier, messages }) {
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
  bumpStat('llmCalls');
  bumpStat('tokensUsed', totalTokens);
  await saveDb();

  data._credits = { used: cost, remaining: getCredits(user), totalTokens };
  sendJson(res, 200, data);
}

// ---------------------------------------------------------------------------
// SSE 流式响应
// ---------------------------------------------------------------------------

async function proxyStream({ req, res, user, config, upstream, multiplier, messages }) {
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
