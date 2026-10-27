# SlipCode 账号后端

零第三方依赖的 Node.js 后端，为 SlipCode 提供：

- 独立账号体系（注册 / 登录 / 用户信息）
- 用户偏好设置的多设备同步
- Gitee OAuth token 代理（Gitee 不支持 PKCE，必须由后端持有 `client_secret`）

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

启动示例：

```bash
JWT_SECRET="$(openssl rand -hex 32)" \
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

## 部署注意

- 生产环境请使用 HTTPS，并把 App 的 `ACCOUNT_BACKEND_BASE_URL` 指向该地址。
- 反向代理需放行 `POST/PUT` 与 `Authorization` 头。
- 当前实现是单实例 JSON 存储，适合个人/小团队；多实例部署需换成数据库与共享会话密钥。
