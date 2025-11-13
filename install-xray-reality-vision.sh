#!/usr/bin/env bash
set -euo pipefail
# Debian 一键部署 Xray (VLESS + REALITY + Vision) + acme.sh 自动续签 + 防火墙持久化 + QR/订阅
# 使用前请确认：在 Debian 系统下，以 root 运行（或 sudo）
# 运行：sudo ./install-xray-reality-vision.sh

GREEN="\033[32m"
YELLOW="\033[33m"
RED="\033[31m"
NC="\033[0m"

info(){ echo -e "${GREEN}[INFO]${NC} $*"; }
warn(){ echo -e "${YELLOW}[WARN]${NC} $*"; }
err(){ echo -e "${RED}[ERROR]${NC} $*"; }

# --- prompts ---
read -rp "请输入你的服务器域名 (e.g. example.com): " SERVER_DOMAIN
read -rp "请输入 Reality 的伪装域名 / SNI (camouflage serverName, e.g. www.cloudflare.com) : " CAMO_DOMAIN
read -rp "监听端口 (默认 443): " PORT
PORT=${PORT:-443}
read -rp "是否自动生成 UUID? [Y/n]: " GEN_UUID_ANS
GEN_UUID_ANS=${GEN_UUID_ANS:-Y}
read -rp "是否使用 acme.sh 自动申请并启用证书? [Y/n]: " USE_ACME_ANS
USE_ACME_ANS=${USE_ACME_ANS:-Y}

# --- defaults / derived ---
XRAY_DIR="/usr/local/bin"
XRAY_CONF_DIR="/etc/xray"
XRAY_CONF_FILE="${XRAY_CONF_DIR}/config.json"
XRAY_SERVICE="/etc/systemd/system/xray.service"
ACME_DIR="/root/.acme.sh"
UUID=""
PRIVATE_KEY=""
PUBLIC_KEY=""
SHORT_ID=""

# --- ensure root ---
if [ "$EUID" -ne 0 ]; then
  err "请用 root 或 sudo 运行此脚本。"
  exit 1
fi

info "更新系统并安装基础依赖..."
export DEBIAN_FRONTEND=noninteractive
apt update -y
apt install -y curl wget tar unzip socat openssl cron ca-certificates lsb-release jq python3 python3-pip

# stop common web servers if blocking ports (so acme standalone can bind)
if systemctl is-active --quiet nginx 2>/dev/null || systemctl is-active --quiet apache2 2>/dev/null; then
  warn "检测到 nginx 或 apache2 正在运行，脚本会临时停止它们以便申请证书（若选择申请证书）"
  systemctl stop nginx || true
  systemctl stop apache2 || true
fi

# --- download latest xray ---
info "下载并安装最新 xray-core..."
ARCH="linux-64"
XRAY_URL=$(curl -s "https://api.github.com/repos/XTLS/Xray-core/releases/latest" \
  | jq -r '.assets[] | select(.name|test("linux-64.zip")) | .browser_download_url' | head -n1)
if [ -z "$XRAY_URL" ]; then
  warn "无法通过 API 自动定位 xray 二进制，尝试使用通用下载 fallback..."
  XRAY_URL="https://github.com/XTLS/Xray-core/releases/latest/download/Xray-linux-64.zip"
fi

TMPDIR=$(mktemp -d)
cd "$TMPDIR"
curl -L -o xray.zip "$XRAY_URL"
unzip -o xray.zip -d xray_dist
install -m 755 xray_dist/xray "${XRAY_DIR}/xray"
mkdir -p "${XRAY_CONF_DIR}"
info "xray 已安装到 ${XRAY_DIR}/xray"

# --- generate credentials ---
if [[ "$GEN_UUID_ANS" =~ ^([yY]| ) ]]; then
  UUID=$("${XRAY_DIR}/xray" uuid)
else
  read -rp "请输入自定义 UUID: " UUID
fi
info "使用 UUID: ${UUID}"

info "生成 Reality x25519 keypair..."
X25519_OUT=$("${XRAY_DIR}/xray" x25519)
PRIVATE_KEY=$(echo "$X25519_OUT" | awk -F': ' '/Private key/{print $2}' | tr -d '\r\n')
PUBLIC_KEY=$(echo "$X25519_OUT" | awk -F': ' '/Public key/{print $2}' | tr -d '\r\n')
if [ -z "$PRIVATE_KEY" ] || [ -z "$PUBLIC_KEY" ]; then
  err "生成 x25519 密钥失败，请检查 xray 是否工作正常。"
  exit 1
fi
info "生成 Private/Public key 完成."

# short id
SHORT_ID=$(openssl rand -hex 8)
info "短 ID (shortId): ${SHORT_ID}"

# --- obtain cert via acme.sh if requested ---
if [[ "$USE_ACME_ANS" =~ ^([yY]| ) ]]; then
  info "安装 acme.sh 并申请证书 (standalone 模式) ..."
  curl -sSfL https://get.acme.sh | sh -s -- --install --nocron
  export PATH="$PATH:/root/.acme.sh"
  "${ACME_DIR}/acme.sh" --issue -d "${SERVER_DOMAIN}" --standalone --yes-I-know-dns-manual-mode-enough || {
    err "acme.sh 申请证书失败，请检查 80/443 端口是否被占用；继续但 Xray 仍会部署（REALITY 可工作）。"
  }
  mkdir -p "${XRAY_CONF_DIR}/cert"
  "${ACME_DIR}/acme.sh" --install-cert -d "${SERVER_DOMAIN}" \
    --key-file "${XRAY_CONF_DIR}/cert/key.pem" \
    --fullchain-file "${XRAY_CONF_DIR}/cert/cert.pem" \
    --reloadcmd "systemctl restart xray || true"
  info "证书已安装到 ${XRAY_CONF_DIR}/cert/"
else
  warn "跳过证书申请（你选择了不自动申请）。"
fi

# --- create simple fallback HTTP server for Vision/TCP fallback ---
mkdir -p /var/www/xray-fallback
cat >/var/www/xray-fallback/index.html <<EOF
<html><body><h1>${SERVER_DOMAIN}</h1><p>Fallback page for Xray Vision/Reality</p></body></html>
EOF

cat >/etc/systemd/system/xray-fallback.service <<'EOF'
[Unit]
Description=Simple fallback http server for Xray
After=network.target

[Service]
Type=simple
WorkingDirectory=/var/www/xray-fallback
ExecStart=/usr/bin/python3 -m http.server 18080 --bind 127.0.0.1
Restart=on-failure
User=root

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable --now xray-fallback.service

# --- generate Xray config.json ---
info "生成 Xray 配置文件..."
cat > "${XRAY_CONF_FILE}" <<EOF
{
  "log": {
    "loglevel": "warning",
    "access": "/var/log/xray-access.log",
    "error": "/var/log/xray-error.log"
  },
  "inbounds": [
    {
      "port": ${PORT},
      "listen": "0.0.0.0",
      "protocol": "vless",
      "settings": {
        "clients": [
          {
            "id": "${UUID}",
            "level": 0,
            "flow": "xtls-rprx-vision"
          }
        ],
        "decryption": "none",
        "fallbacks": [
          {
            "dest": "127.0.0.1:18080",
            "xver": 1
          }
        ]
      },
      "streamSettings": {
        "network": "tcp",
        "security": "reality",
        "realitySettings": {
          "privateKey": "${PRIVATE_KEY}",
          "shortIds": [
            "${SHORT_ID}"
          ],
          "serverNames": [
            "${CAMO_DOMAIN}"
          ],
          "dest": "127.0.0.1:18080",
          "handshake": "",
          "show": false,
          "xver": 0
        }
      }
    }
  ],
  "outbounds": [
    {
      "protocol": "freedom"
    }
  ]
}
EOF

chown -R root:root "${XRAY_CONF_DIR}"
chmod 600 "${XRAY_CONF_FILE}"

# --- systemd service for xray ---
info "创建 systemd 服务..."
cat > "${XRAY_SERVICE}" <<EOF
[Unit]
Description=Xray - A unified proxy
After=network.target

[Service]
Type=simple
User=root
ExecStart=${XRAY_DIR}/xray -config ${XRAY_CONF_FILE}
Restart=on-failure
LimitNOFILE=65536

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable --now xray.service

# --- firewall and iptables-persistent ---
info "尝试开放防火墙端口 ${PORT} ..."
apt install -y iptables-persistent
iptables -C INPUT -p tcp --dport "${PORT}" -j ACCEPT 2>/dev/null || \
    iptables -I INPUT -p tcp --dport "${PORT}" -j ACCEPT
netfilter-persistent save || true
info "防火墙规则已持久化: 端口 ${PORT} TCP 放行"

# --- certificate auto-renew & logrotate ---
if [[ "$USE_ACME_ANS" =~ ^([yY]| ) ]]; then
  info "配置 acme.sh 自动续签..."
  crontab -l | grep -q acme.sh || (
    (crontab -l 2>/dev/null; echo "0 0 * * * ${ACME_DIR}/acme.sh --cron --home ${ACME_DIR} > /dev/null") | crontab -
  )
fi

cat >/etc/logrotate.d/xray <<'EOF'
/var/log/xray-*.log {
    daily
    missingok
    rotate 7
    compress
    delaycompress
    notifempty
    create 640 root adm
    sharedscripts
    postrotate
        systemctl restart xray > /dev/null 2>/dev/null || true
    endscript
}
EOF
info "日志轮转已配置：每天轮转，保留最近 7 天压缩日志"

# --- generate VLESS QR and subscription ---
info "生成 VLESS Reality+Vision 客户端二维码及订阅格式..."
apt install -y qrencode
VLESS_URI="vless://${UUID}@${SERVER_DOMAIN}:${PORT}?security=reality&type=tcp&flow=xtls-rprx-vision&pbk=${PUBLIC_KEY}&sid=${SHORT_ID}&sni=${CAMO_DOMAIN}#${SERVER_DOMAIN}-reality-vision"
CONFIG_DIR="/root/xray-client-config"
mkdir -p "$CONFIG_DIR"
echo "${VLESS_URI}" > "${CONFIG_DIR}/vless-reality-vision.txt"
qrencode -o "${CONFIG_DIR}/vless-reality-vision.png" -t PNG "${VLESS_URI}"

info "VLESS URI 已保存到: ${CONFIG_DIR}/vless-reality-vision.txt"
info "二维码已保存到: ${CONFIG_DIR}/vless-reality-vision.png"
info "终端二维码如下（可直接扫码）："
qrencode -t UTF8 "${VLESS_URI}"

# --- done ---
info "部署完成！下面是重要信息（请保存）："
echo
echo "UUID: ${UUID}"
echo "Reality PrivateKey (server): ${PRIVATE_KEY}"
echo "Reality PublicKey (client): ${PUBLIC_KEY}"
echo "shortId: ${SHORT_ID}"
echo "server domain: ${SERVER_DOMAIN}"
echo "reality serverName (camouflage/SNI): ${CAMO_DOMAIN}"
echo "port: ${PORT}"
echo "VLESS URI: ${VLESS_URI}"
echo
info "日志路径: /var/log/xray-access.log  /var/log/xray-error.log"
info "证书路径: ${XRAY_CONF_DIR}/cert/ (若启用 acme.sh)"
info "防火墙规则已持久化，端口 ${PORT} 已放行"
info "二维码和订阅文件保存在: ${CONFIG_DIR}/"
info "脚本执行完毕，祝顺利！"
