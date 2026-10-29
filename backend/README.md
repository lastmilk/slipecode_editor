# SlipCode 账号后端

零第三方依赖的 Node.js 后端，为 SlipCode 提供：

- 独立账号体系（注册 / 登录 / 用户信息）
- 用户偏好设置的多设备同步
- Gitee OAuth token 代理（Gitee 不支持 PKCE，必须由后端持有 `client_secret`）
- 积分体系：每日签到 +100 积分，积分用于抵扣内置 LLM 调用
- LLM 内置代理：OpenAI 兼容 `/chat/completions`，按 token 计积分
- 管理端：`/admin` 静态页面 + `/api/admin/*` 接口（用户积分调整、LLM 模型管理）

## 运行

需要 Node.js 18+。

```bash
cd backend
npm start
```

默认监听 `8787` 端口，数据保存在 `backend/data/db.json`（已 gitignore）。

## 环境变量

| 变量 | 必填 | 说明 |
| --- | --- | --- |
| `PORT` | 否 | 监听端口，默认 `8787` |
| `JWT_SECRET` | 生产必填 | 签发登录 token 的密钥，务必使用足够长的随机字符串 |
| `DATA_DIR` | 否 | 数据目录，默认 `backend/data` |
| `CORS_ORIGIN` | 否 | 允许的跨域来源，默认 `*` |
| `GITEE_CLIENT_ID` | Gitee 必填 | Gitee 应用的 Client ID |
| `GITEE_CLIENT_SECRET` | Gitee 必填 | Gitee 应用的 Client Secret |
| `GITEE_REDIRECT_URI` | 否 | Gitee 回调地址，默认 `slipecode://oauth/gitee/callback` |
| `ADMIN_TOKEN` | 生产必填 | 管理端访问令牌，**必须改为足够长的随机串**；未设置时使用代码内的开发默认值（启动时会打印警告） |

启动示例：

```bash
JWT_SECRET="$(openssl rand -hex 32)" \
ADMIN_TOKEN="$(openssl rand -hex 32)" \
GITEE_CLIENT_ID=xxx \
GITEE_CLIENT_SECRET=xxx \
node src/server.js
```

## 接口

| 方法 | 路径 | 说明 |
| --- | --- | --- |
| `GET` | `/api/health` | 健康检查 |
| `POST` | `/api/auth/register` | `{email, password, displayName}` → `{token, user}` |
| `POST` | `/api/auth/login` | `{email, password}` → `{token, user}` |
| `GET` | `/api/me` | 需 `Authorization: Bearer <token>`，返回当前用户 |
| `GET` | `/api/settings` | 需登录，返回 `{settings}` |
| `PUT` | `/api/settings` | 需登录，`{settings}` 保存偏好设置 |
| `POST` | `/api/oauth/gitee/token` | `{code, redirect_uri}` → Gitee token（供 App 使用） |
| `POST` | `/api/oauth/gitee/refresh` | `{refresh_token}` → 续期 Gitee token |
| `POST` | `/api/checkin` | 需登录，每日签到 +100 积分；当天重复签到返回「今日已签到」（`checkedInToday: true`） |
| `GET` | `/api/credits` | 需登录，返回 `{credits, checkedInToday}` |
| `GET` | `/api/llm/models` | 需登录，返回可用模型列表（仅 `id`/`name`/`multiplier`，不含 `apiKey`） |
| `POST` | `/api/llm/chat` | 需登录，OpenAI 兼容代理，body `{model, messages, temperature?}` |

### 积分规则

- 每个用户有 `credits` 字段（默认 0），每日签到 `POST /api/checkin` 得 +100 积分，按服务器本地日期（`YYYY-MM-DD`）判断是否已签到（`lastCheckinDate`）。
- LLM 调用计价：**1 积分 = 2000 token**。每次调用按响应 `usage.total_tokens` 扣费：`ceil(total_tokens / 2000 * multiplier)`（`multiplier` 为该模型的消耗倍率，默认 1.0）。
- 若上游响应没有 `usage` 字段，按 `prompt 字符数/4 + completion 字符数/4` 估算 token。
- 积分不足时返回 HTTP `402`：`{ "error": "积分不足", "credits": <余额> }`（不会扣费）。
- 扣费成功的响应体内附加 `_credits: { used, remaining }` 字段。

### 管理端

浏览器访问 `https://ser1996.niav.cn/admin`（或 `/admin/`），输入 `ADMIN_TOKEN` 登录后可：

- 查看用户列表（邮箱 / 积分 / 注册时间 / 最后签到），并对用户积分加 / 减；
- 查看、新增、编辑、删除 LLM 模型（字段：`name` / `apiBase` / `apiKey` / `model` / `multiplier`）。

管理接口（需 `Authorization: Bearer <ADMIN_TOKEN>`）：

| 方法 | 路径 | 说明 |
| --- | --- | --- |
| `GET` | `/api/admin/users` | 用户列表 |
| `POST` | `/api/admin/users/:email/credits` | `{delta: 100}`，可正可负（非零整数） |
| `GET` | `/api/admin/llm/models` | 模型完整列表（**含 apiKey**） |
| `POST` | `/api/admin/llm/models` | 新增模型 `{name, apiBase, apiKey, model, multiplier?}` |
| `PUT` | `/api/admin/llm/models/:id` | 编辑模型（字段均可选，按需传） |
| `DELETE` | `/api/admin/llm/models/:id` | 删除模型 |

## 部署注意

- 生产环境请使用 HTTPS，并把 App 的 `ACCOUNT_BACKEND_BASE_URL` 指向该地址。
- 反向代理需放行 `POST/PUT` 与 `Authorization` 头。
- 当前实现是单实例 JSON 存储，适合个人/小团队；多实例部署需换成数据库与共享会话密钥。
