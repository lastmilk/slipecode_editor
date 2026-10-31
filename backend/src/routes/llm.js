// LLM 内置代理（OpenAI 兼容 /chat/completions，按 token 扣积分）

import { TOKENS_PER_CREDIT } from '../config.js';
import { bumpStat, getDb, saveDb } from '../db.js';
import { readJson, sendJson } from '../http.js';
import { requireUser } from '../security.js';
import { getCredits } from './me.js';

function publicLlmModel(m) {
  return { id: m.id, name: m.name, multiplier: m.multiplier ?? 1 };
}

export async function handleLlmModels(req, res) {
  requireUser(req);
  sendJson(res, 200, { models: getDb().llmModels.map(publicLlmModel) });
}

/** 上游没有返回 usage 时按字符数粗略估算 token（约 4 字符 ≈ 1 token） */
function estimateTokens(messages, data) {
  const promptChars = messages.reduce((sum, m) => {
    if (typeof m?.content === 'string') return sum + m.content.length;
    return sum + JSON.stringify(m?.content ?? '').length;
  }, 0);
  const completionChars = Array.isArray(data?.choices)
    ? data.choices.reduce(
        (sum, c) =>
          sum + (typeof c?.message?.content === 'string' ? c.message.content.length : 0),
        0,
      )
    : 0;
  return Math.ceil(promptChars / 4) + Math.ceil(completionChars / 4);
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
  if (balance <= 0) {
    return sendJson(res, 402, { error: '积分不足', credits: balance });
  }

  const upstreamBody = { model: config.model, messages: body.messages };
  if (body.temperature !== undefined) upstreamBody.temperature = body.temperature;
  // Agent 的 MCP 工具调用需要透传 function-calling 参数
  if (Array.isArray(body.tools) && body.tools.length > 0) {
    upstreamBody.tools = body.tools;
    if (body.tool_choice !== undefined) upstreamBody.tool_choice = body.tool_choice;
  }

  let upstream;
  let text;
  try {
    upstream = await fetch(
      `${String(config.apiBase).replace(/\/+$/, '')}/chat/completions`,
      {
        method: 'POST',
        headers: {
          'Content-Type': 'application/json',
          Authorization: `Bearer ${config.apiKey}`,
        },
        body: JSON.stringify(upstreamBody),
        signal: AbortSignal.timeout(120_000),
      },
    );
    text = await upstream.text();
  } catch {
    return sendJson(res, 502, { error: '无法连接上游模型服务' });
  }

  let data;
  try {
    data = JSON.parse(text);
  } catch {
    data = null;
  }
  if (!upstream.ok || !data) {
    return sendJson(res, 502, {
      error: '上游模型调用失败',
      upstreamStatus: upstream.status,
      detail: text.slice(0, 300),
    });
  }

  const totalTokens =
    data.usage && Number.isFinite(data.usage.total_tokens)
      ? data.usage.total_tokens
      : estimateTokens(body.messages, data);
  const multiplier = Number.isFinite(config.multiplier) ? config.multiplier : 1;
  const cost = Math.ceil((totalTokens / TOKENS_PER_CREDIT) * multiplier);

  if (getCredits(user) < cost) {
    return sendJson(res, 402, { error: '积分不足', credits: getCredits(user) });
  }
  user.credits = getCredits(user) - cost;
  bumpStat('llmCalls');
  bumpStat('tokensUsed', totalTokens);
  await saveDb();

  data._credits = { used: cost, remaining: user.credits };
  sendJson(res, 200, data);
}
