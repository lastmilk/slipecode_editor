#!/bin/bash
# SLIPE 账号后端部署脚本（宝塔面板 · CentOS）
#
# 使用前提：
#   1. 已在宝塔「网站 → 反向代理」创建站点 api.lineregre.com，目标 http://127.0.0.1:8787
#      （管理页域名 workadmin.lineregre.com 也反代到同一进程即可）
#   2. 已把 backend-deploy.zip 上传到 /www/wwwroot/api.lineregre.com/
#   3. 以 root 在面板「终端」执行：bash /www/wwwroot/api.lineregre.com/deploy.sh
set -euo pipefail

DOMAIN="api.lineregre.com"
ROOT="/www/wwwroot/${DOMAIN}"
ZIP="${ROOT}/backend-deploy.zip"
NODE_DIR="/www/server/nodejs/v20.18.0"
NODE="${NODE_DIR}/bin/node"

echo "==> 1/5 检查 Node.js"
if [ ! -x "$NODE" ]; then
  echo "安装 Node.js v20.18.0 ..."
  mkdir -p /www/server/nodejs
  cd /tmp
  curl -fsSL -o node.tar.xz https://npmmirror.com/mirrors/node/v20.18.0/node-v20.18.0-linux-x64.tar.xz
  tar -xJf node.tar.xz
  rm -rf "$NODE_DIR"
  mv node-v20.18.0-linux-x64 "$NODE_DIR"
  rm -f node.tar.xz
  ln -sfn "$NODE_DIR" /www/server/nodejs/current
  ln -sf "$NODE" /usr/local/bin/node
  ln -sf "${NODE_DIR}/bin/npm" /usr/local/bin/npm
fi
"$NODE" -v

echo "==> 2/5 解压后端代码"
[ -f "$ZIP" ] || { echo "缺少 $ZIP，请先上传 backend-deploy.zip 到站点根目录"; exit 1; }
rm -rf "${ROOT}/api"
mkdir -p "${ROOT}/api"
unzip -oq "$ZIP" -d "${ROOT}/api"
APP="${ROOT}/api/backend"
[ -f "$APP/src/server.js" ] || { echo "解压异常：找不到 src/server.js"; exit 1; }

echo "==> 3/5 生成环境变量"
if [ ! -f "$APP/.env" ]; then
  umask 077
  cat > "$APP/.env" <<EOF
PORT=8787
DATA_DIR=${ROOT}/api/data
JWT_SECRET=$(openssl rand -hex 32)
CORS_ORIGIN=*
GITHUB_REDIRECT_URI=https://api.lineregre.com/api/oauth/github/callback
GITHUB_DEEP_LINK=slipe://gitoauth2
GITEE_CLIENT_ID=
GITEE_CLIENT_SECRET=
GITEE_REDIRECT_URI=slipe://oauth/gitee/callback
EOF
  chmod 600 "$APP/.env"
  echo "已生成 $APP/.env（含随机 JWT_SECRET）"
else
  echo "已存在 $APP/.env，保持不变"
fi
mkdir -p "${ROOT}/api/data"

echo "==> 4/5 注册 systemd 服务"
cat > /etc/systemd/system/slipe-api.service <<EOF
[Unit]
Description=SLIPE Account Backend
After=network-online.target

[Service]
Type=simple
WorkingDirectory=${APP}
EnvironmentFile=${APP}/.env
ExecStart=${NODE} src/server.js
Restart=always
RestartSec=3
LimitNOFILE=65535

[Install]
WantedBy=multi-user.target
EOF
systemctl daemon-reload
systemctl enable slipe-api >/dev/null 2>&1
systemctl restart slipe-api

echo "==> 5/5 自检"
sleep 2
systemctl --no-pager --lines=5 status slipe-api || true
echo -n "本地健康检查: "
curl -sS --max-time 5 http://127.0.0.1:8787/api/health || echo "(失败)"
echo
