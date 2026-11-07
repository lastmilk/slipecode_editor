# SLIPE 账号后端

零第三方依赖的 Node.js 后端，为 SLIPE 提供：

- 独立账号体系（注册 / 登录 / 用户信息，注册需手机号短信验证）
- 极验 GT4 行为验证（登录 / 注册前校验，可开关）
- 阿里云短信验证码（DyPnsApi 2017-05-25，未配置凭据时自动降级为开发模式）
- 用户偏好设置的多设备同步
- 项目列表 / AI 对话记录 / 头像 / 壁纸的云端同步
- Gitee OAuth token 代理（Gitee 不支持 PKCE，必须由后端持有 `client_secret`）
- 积分体系：每日签到 +100 积分，积分用于抵扣内置 LLM 调用
- LLM 内置代理：OpenAI 兼容 `/chat/completions`，按 token 计积分
- 管理端：`workadmin.lineregre.com` Element Plus 管理页 + `/api/admin/*` 接口（凭据配置、统计、用户详情二次验证、积分调整、LLM 模型管理）

## 运行

需要 Node.js 18+。

```bash
cd backend
npm start
```

默认监听 `8787` 端口，数据保存在 `backend/data/db.json`（已 gitignore）。

域名约定（同一进程可同时服务两个域名）：

| 域名 | 用途 |
| --- | --- |
| `api.lineregre.com` | 全部 `/api/*` 接口（App 的 `ACCOUNT_BACKEND_BASE_URL`） |
| `workadmin.lineregre.com` | Element Plus 管理页面（根路径即管理端） |

本地开发可直接访问 `http://localhost:8787/admin`。交由 Nginx/宝塔做 HTTPS 与反向代理时，两个站点都反代到同一个 `127.0.0.1:8787` 即可。

## 运行期配置

极验、阿里云、管理员密码可在管理页「凭据配置」中直接修改并立即生效，写入 `db.json` 的 `config` 字段，优先级高于环境变量。环境变量仅作为初始值/兜底。

## 环境变量

| 变量 | 必填 | 说明 |
| --- | --- | --- |
| `PORT` | 否 | 监听端口，默认 `8787` |
| `JWT_SECRET` | 生产必填 | 签发登录 token 的密钥，务必使用足够长的随机字符串 |
| `DATA_DIR` | 否 | 数据目录，默认 `backend/data` |
| `CORS_ORIGIN` | 否 | 允许的跨域来源，默认 `*` |
| `GITEE_CLIENT_ID` | Gitee 必填 | Gitee 应用的 Client ID |
| `GITEE_CLIENT_SECRET` | Gitee 必填 | Gitee 应用的 Client Secret |
| `GITEE_REDIRECT_URI` | 否 | Gitee 回调地址，默认 `slipe://oauth/gitee/callback` |
| `GITHUB_CLIENT_ID` | GitHub 必填 | GitHub OAuth App 的 Client ID |
| `GITHUB_CLIENT_SECRET` | GitHub 必填 | GitHub OAuth App 的 Client Secret |
| `GITHUB_REDIRECT_URI` | 否 | GitHub OAuth App 里登记的 callback URL，默认 `https://api.lineregre.com/api/oauth/github/callback` |
| `GITHUB_DEEP_LINK` | 否 | 换 token 后 302 回 App 的深链，默认 `slipe://gitoauth2` |
| `ADMIN_PASSWORD` | 否 | 管理员初始密码，默认 `slipe-admin-2026`；登录后请在管理页修改（修改后写入数据库哈希，环境变量不再生效） |
| `ADMIN_TOKEN` | 否 | 可选静态管理令牌（兼容脚本调用），一般无需设置 |
| `GEETEST_CAPTCHA_ID` | 生产必填 | 极验 GT4 Captcha ID（登录 / 注册二次校验） |
| `GEETEST_CAPTCHA_KEY` | 生产必填 | 极验 GT4 Captcha Key（HMAC-SHA256 校验 sign_token） |
| `GEETEST_ENFORCE` | 否 | 默认 `1`：强制校验极验；设为 `0` 可临时关闭 |
| `ALIYUN_ACCESS_KEY_ID` | 短信必填 | 阿里云 AccessKey ID（未配置时进入短信开发模式，固定验证码 `123456`） |
| `ALIYUN_ACCESS_KEY_SECRET` | 短信必填 | 阿里云 AccessKey Secret |
| `ALIYUN_SMS_SIGN_NAME` | 否 | 短信签名，默认 `恒创联众` |
| `ALIYUN_SMS_TEMPLATE_CODE` | 否 | 短信模板 Code，默认 `100001` |
| `UPLOAD_DIR` | 否 | 头像 / 壁纸上传目录，默认 `backend/data/uploads` |
| `UPLOAD_BODY_LIMIT` | 否 | 上传请求体上限，默认 `8388608`（8MB） |
| `AVATAR_MAX` | 否 | 头像大小上限，默认 `2097152`（2MB） |
| `WALLPAPER_MAX` | 否 | 壁纸大小上限，默认 `5242880`（5MB） |

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
| `POST` | `/api/auth/register` | `{email, password, displayName, phone, smsCode, captcha?, captchaPlatform}` → `{token, user}` |
| `POST` | `/api/auth/login` | `{email, password, captcha?, captchaPlatform}` → `{token, user}` |
| `POST` | `/api/auth/sms/send` | `{phone}` → 发送注册短信验证码（开发模式返回 `{devMode: true, devCode: '123456'}`；同一号码 60 秒内限 1 次、每日限 5 次） |
| `POST` | `/api/auth/captcha/validate` | 极验二次校验（App 一般不需要直接调用，注册 / 登录接口内部已校验） |
| `GET` | `/api/projects` | 需登录，返回云端项目列表（路径 + 仓库映射 + 最近编辑时间，≤100 条） |
| `PUT` | `/api/projects` | 需登录，`{projects}` 全量保存项目列表 |
| `GET` | `/api/chat/history` | 需登录，返回 AI 对话记录（≤200 条） |
| `PUT` | `/api/chat/history` | 需登录，`{messages}` 全量保存对话记录 |
| `DELETE` | `/api/chat/history` | 需登录，清空对话记录 |
| `POST` | `/api/me/avatar` | 需登录，`{dataBase64, mime}` 上传头像（png/jpg/webp，≤2MB） |
| `GET` | `/api/avatars/:userId` | 获取用户头像（支持 `?v=` 缓存破坏） |
| `POST` | `/api/me/wallpaper` | 需登录，`{dataBase64, mime}` 上传壁纸（png/jpg/webp，≤5MB） |
| `GET` | `/api/me/wallpaper` | 需登录，下载壁纸 `{mime, version, dataBase64}` |
| `DELETE` | `/api/me/wallpaper` | 需登录，删除云端壁纸 |
| `GET` | `/api/me` | 需 `Authorization: Bearer <token>`，返回当前用户 |
| `GET` | `/api/settings` | 需登录，返回 `{settings}` |
| `PUT` | `/api/settings` | 需登录，`{settings}` 保存偏好设置 |
| `POST` | `/api/oauth/gitee/token` | `{code, redirect_uri}` → Gitee token（供 App 使用） |
| `POST` | `/api/oauth/gitee/refresh` | `{refresh_token}` → 续期 Gitee token |
| `GET` | `/api/oauth/github/callback` | GitHub 回调中转：后端用 client_secret 换 token，再 302 回 `slipe://gitoauth2?ticket=...` |
| `POST` | `/api/oauth/github/token` | `{ticket}`（推荐）或 `{code, redirect_uri}` → GitHub token（供 App 使用） |
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

浏览器访问 `https://workadmin.lineregre.com`（或本地 `/admin`），输入管理员密码登录（默认 `slipe-admin-2026`，可通过 `ADMIN_PASSWORD` 修改初始值）。登录后签发 8 小时有效的管理员 JWT。

管理页提供：

- **概览统计**：注册 / 登录 / 短信 / 极验通过率 / LLM 调用与 token，14 天趋势，服务状态与凭据状态；
- **用户管理**：搜索用户、调整积分；查看用户详情需**二次输入管理员密码**（`X-Admin-Password`）；
- **凭据配置**：极验 Captcha ID / Key / 强制开关，阿里云 AccessKey / 短信签名 / 模板，管理员密码修改；
- **LLM 模型**：查看、新增、编辑、删除模型（字段：`name` / `apiBase` / `apiKey` / `model` / `multiplier`）。

管理接口（需 `Authorization: Bearer <管理员 JWT>`）：

| 方法 | 路径 | 说明 |
| --- | --- | --- |
| `POST` | `/api/admin/login` | `{password}` → `{token, expiresIn, mustChangePassword}` |
| `GET` | `/api/admin/session` | 校验登录态 |
| `GET` | `/api/admin/stats` | 统计数据（总量 / 今日 / 14 天 / 用户 / 内容 / 凭据 / 服务） |
| `GET` | `/api/admin/config` | 读取凭据配置（密钥仅返回掩码） |
| `PUT` | `/api/admin/config` | 保存凭据配置；`adminPassword` 需同时传 `currentAdminPassword` |
| `GET` | `/api/admin/users` | 用户列表，支持 `?q=` 搜索 |
| `GET` | `/api/admin/users/:id` | 用户详情，**额外需要 `X-Admin-Password` 头** |
| `POST` | `/api/admin/users/:id/credits` | `{delta: 100}`，可正可负（非零整数） |
| `GET` | `/api/admin/llm/models` | 模型完整列表（**含 apiKey**） |
| `POST` | `/api/admin/llm/models` | 新增模型 `{name, apiBase, apiKey, model, multiplier?}` |
| `PUT` | `/api/admin/llm/models/:id` | 编辑模型（字段均可选，按需传） |
| `DELETE` | `/api/admin/llm/models/:id` | 删除模型 |

## 部署注意

- 生产环境请使用 HTTPS，并把 App 的 `ACCOUNT_BACKEND_BASE_URL` 指向 `https://api.lineregre.com`。
- `api.lineregre.com` 与 `workadmin.lineregre.com` 都反代到同一进程（默认 `127.0.0.1:8787`）；管理页按 Host 头返回。
- 反向代理需放行 `POST/PUT/DELETE`、`Authorization` 与 `X-Admin-Password` 头。
- 首次上线后请立即在管理页修改默认管理员密码，并配置极验 / 阿里云凭据。
- 当前实现是单实例 JSON 存储，适合个人/小团队；多实例部署需换成数据库与共享会话密钥。
