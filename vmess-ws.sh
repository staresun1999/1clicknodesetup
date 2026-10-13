#!/usr/bin/env bash
# =====================================================================
# VMess + WebSocket 一键安装脚本（Xray-core）  适用：Ubuntu / Debian
# 互动式：运行后按提示输入配置，直接回车则使用 [默认值]（随机生成）
#
# 用法：
#   bash vmess-ws.sh
#
# 也支持用环境变量预设默认值（PORT / DOMAIN / UUID / WS_PATH / NODE_NAME）；
# 若没有可用的终端（如被其他程序调用），则跳过提问，直接使用默认值/环境变量。
#
# 完成后输出 Clash Mihomo 格式节点，并保存到 /root/clash-vmess-node.yaml
# =====================================================================
set -euo pipefail

PORT="${PORT:-}"
DOMAIN="${DOMAIN:-}"
UUID="${UUID:-}"
WS_PATH="${WS_PATH:-}"
NODE_NAME="${NODE_NAME:-vmess-ws}"

XRAY_BIN=/usr/local/bin/xray
XRAY_CONF=/usr/local/etc/xray/config.json
OUT_FILE=/root/clash-vmess-node.yaml

info() { echo -e "\033[32m[INFO]\033[0m $*"; }
warn() { echo -e "\033[33m[WARN]\033[0m $*"; }
die()  { echo -e "\033[31m[ERROR]\033[0m $*" >&2; exit 1; }

# ---------- 环境检查 ----------
[[ $EUID -eq 0 ]] || die "请使用 root 运行"
command -v apt-get >/dev/null || die "仅支持 Ubuntu / Debian"
command -v systemctl >/dev/null || die "需要 systemd"

info "安装依赖..."
export DEBIAN_FRONTEND=noninteractive
apt-get update -y >/dev/null
apt-get install -y curl ca-certificates iproute2 unzip >/dev/null

# ---------- 工具函数 ----------
port_in_use() { ss -ltn "( sport = :$1 )" | grep -q LISTEN; }

rand_port() {
  local p
  while :; do
    p=$(shuf -i 10000-60000 -n 1)
    port_in_use "$p" || { echo "$p"; return; }
  done
}

get_ip() {
  local u ip
  for u in https://api.ipify.org https://icanhazip.com https://ifconfig.me; do
    ip=$(curl -4 -fsS --max-time 5 "$u" 2>/dev/null | tr -d '[:space:]') || true
    [[ -n "$ip" ]] && { echo "$ip"; return; }
  done
}

valid_domain() { [[ "$1" =~ ^([A-Za-z0-9]([A-Za-z0-9-]*[A-Za-z0-9])?\.)+[A-Za-z]{2,}$ ]]; }
valid_uuid()   { [[ "$1" =~ ^[0-9a-fA-F]{8}-([0-9a-fA-F]{4}-){3}[0-9a-fA-F]{12}$ ]]; }
valid_path()   { [[ "$1" =~ ^/[A-Za-z0-9/_.-]*$ ]]; }
valid_port()   { [[ "$1" =~ ^[0-9]+$ ]] && (( $1 >= 1 && $1 <= 65535 )); }

# 是否有可交互的终端（即使脚本是通过 curl | bash 运行也能读取）
INTERACTIVE=0
if { : < /dev/tty; } 2>/dev/null; then INTERACTIVE=1; fi

# ask "提示语" -> 输出用户输入（已去除首尾空白）
ask() {
  local ans=""
  { printf '%s' "$1" > /dev/tty; } 2>/dev/null || true
  read -r ans < /dev/tty 2>/dev/null || ans=""
  ans="${ans#"${ans%%[![:space:]]*}"}"
  ans="${ans%"${ans##*[![:space:]]}"}"
  printf '%s' "$ans"
}

SERVER_IP=$(get_ip)
[[ -n "$SERVER_IP" ]] || die "无法获取公网 IP"

# ---------- 交互式配置 ----------
if (( INTERACTIVE )); then
  echo
  echo "================ 配置（直接回车使用 [默认值]）================"

  # 1) 域名
  while :; do
    ans=$(ask "1) 域名（填写则启用 TLS + Caddy，留空则直连 IP 无 TLS） [${DOMAIN:-不使用}]: ")
    ans="${ans:-$DOMAIN}"
    if [[ -z "$ans" ]] || valid_domain "$ans"; then DOMAIN="$ans"; break; fi
    warn "域名格式不正确，请重新输入"
  done

  # 2) 端口（仅无域名模式需要；域名模式固定 443）
  if [[ -z "$DOMAIN" ]]; then
    while :; do
      ans=$(ask "2) 监听端口 [${PORT:-随机}]: ")
      ans="${ans:-$PORT}"
      if [[ -z "$ans" ]]; then PORT=""; break; fi
      if ! valid_port "$ans"; then warn "端口无效（1-65535）"; continue; fi
      if port_in_use "$ans"; then warn "端口 $ans 已被占用"; continue; fi
      PORT="$ans"; break
    done
  else
    echo "2) 端口：域名模式固定使用 443（Xray 内部端口自动分配）"
  fi

  # 3) UUID
  while :; do
    ans=$(ask "3) UUID [${UUID:-随机生成}]: ")
    ans="${ans:-$UUID}"
    if [[ -z "$ans" ]] || valid_uuid "$ans"; then UUID="$ans"; break; fi
    warn "UUID 格式不正确，应形如 xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx"
  done

  # 4) WS 路径
  while :; do
    ans=$(ask "4) WebSocket 路径，如 /ws [${WS_PATH:-随机生成}]: ")
    ans="${ans:-$WS_PATH}"
    [[ -n "$ans" && "$ans" != /* ]] && ans="/$ans"
    if [[ -z "$ans" ]] || valid_path "$ans"; then WS_PATH="$ans"; break; fi
    warn "路径只能包含字母、数字及 / _ . -"
  done

  # 5) 节点名称
  ans=$(ask "5) 节点名称 [${NODE_NAME}]: ")
  ans="${ans//\"/}"
  NODE_NAME="${ans:-$NODE_NAME}"
else
  info "未检测到终端，跳过提问，使用默认值/环境变量"
  [[ -z "$DOMAIN" ]]  || valid_domain "$DOMAIN" || die "DOMAIN 格式不正确"
  [[ -z "$PORT" ]]    || valid_port "$PORT"     || die "PORT 无效"
  [[ -z "$UUID" ]]    || valid_uuid "$UUID"     || die "UUID 格式不正确"
  [[ -z "$WS_PATH" || "$WS_PATH" == /* ]] || WS_PATH="/$WS_PATH"
  [[ -z "$WS_PATH" ]] || valid_path "$WS_PATH"  || die "WS_PATH 含非法字符"
  NODE_NAME="${NODE_NAME//\"/}"
fi

# ---------- 补全默认值 ----------
[[ -n "$UUID" ]]    || UUID=$(cat /proc/sys/kernel/random/uuid)
[[ -n "$WS_PATH" ]] || WS_PATH="/$(cut -d- -f1 /proc/sys/kernel/random/uuid)"

if [[ -n "$DOMAIN" ]]; then
  # 域名模式：Xray 只监听本机，Caddy 在 443 做 TLS 并反代 WS
  LISTEN=127.0.0.1
  XRAY_PORT=$(rand_port)
  CLIENT_PORT=443
  SERVER="$DOMAIN"
  if ! systemctl is-active --quiet caddy; then
    port_in_use 80  && die "80 端口已被占用，Caddy 申请证书需要 80/443"
    port_in_use 443 && die "443 端口已被占用，Caddy 需要 443"
  fi
  RESOLVED=$(getent ahostsv4 "$DOMAIN" | awk '{print $1; exit}' || true)
  if [[ "$RESOLVED" != "$SERVER_IP" ]]; then
    warn "域名 $DOMAIN 解析到 '${RESOLVED:-无}'，本机 IP 为 $SERVER_IP。"
    warn "若未走 CDN，请先把 A 记录指向本机，否则证书申请会失败。"
  fi
else
  LISTEN=0.0.0.0
  [[ -n "$PORT" ]] || PORT=$(rand_port)
  port_in_use "$PORT" && die "端口 $PORT 已被占用"
  XRAY_PORT=$PORT
  CLIENT_PORT=$PORT
  SERVER="$SERVER_IP"
fi

# ---------- 确认 ----------
echo
echo "================ 配置确认 ================"
if [[ -n "$DOMAIN" ]]; then
  echo "模式      : VMess + WS + TLS（Caddy 自动证书）"
else
  echo "模式      : VMess + WS（无 TLS）"
fi
echo "地址      : ${SERVER}"
echo "端口      : ${CLIENT_PORT}"
echo "UUID      : ${UUID}"
echo "WS 路径   : ${WS_PATH}"
echo "节点名称  : ${NODE_NAME}"
echo "=========================================="
if (( INTERACTIVE )); then
  ans=$(ask "确认开始安装？[Y/n]: ")
  [[ ! "$ans" =~ ^[Nn] ]] || die "已取消"
fi

# ---------- 安装 Xray ----------
info "安装 Xray-core..."
curl -fsSL -o /tmp/xray-install.sh \
  https://github.com/XTLS/Xray-install/raw/main/install-release.sh \
  || die "下载 Xray 安装脚本失败，请检查 VPS 到 GitHub 的连通性"
bash /tmp/xray-install.sh install >/dev/null
rm -f /tmp/xray-install.sh
[[ -x "$XRAY_BIN" ]] || die "Xray 安装失败"

mkdir -p "$(dirname "$XRAY_CONF")"
cat > "$XRAY_CONF" <<EOF
{
  "log": { "loglevel": "warning" },
  "inbounds": [
    {
      "listen": "${LISTEN}",
      "port": ${XRAY_PORT},
      "protocol": "vmess",
      "settings": {
        "clients": [ { "id": "${UUID}", "alterId": 0 } ]
      },
      "streamSettings": {
        "network": "ws",
        "wsSettings": { "path": "${WS_PATH}" }
      }
    }
  ],
  "outbounds": [ { "protocol": "freedom" } ]
}
EOF
chmod 644 "$XRAY_CONF"

"$XRAY_BIN" run -test -config "$XRAY_CONF" >/dev/null || die "Xray 配置校验失败"
systemctl enable xray >/dev/null 2>&1
systemctl restart xray
sleep 1
systemctl is-active --quiet xray || die "Xray 启动失败，请查看：journalctl -u xray -n 50"

# ---------- 域名模式：Caddy 反代 + 自动 TLS ----------
if [[ -n "$DOMAIN" ]]; then
  if ! command -v caddy >/dev/null; then
    info "安装 Caddy..."
    apt-get install -y debian-keyring debian-archive-keyring apt-transport-https gnupg >/dev/null
    curl -fsSL 'https://dl.cloudsmith.io/public/caddy/stable/gpg.key' \
      | gpg --dearmor --yes -o /usr/share/keyrings/caddy-stable-archive-keyring.gpg
    curl -fsSL 'https://dl.cloudsmith.io/public/caddy/stable/debian.deb.txt' \
      > /etc/apt/sources.list.d/caddy-stable.list
    apt-get update -y >/dev/null
    apt-get install -y caddy >/dev/null
  fi

  [[ -f /etc/caddy/Caddyfile ]] && cp -f /etc/caddy/Caddyfile "/etc/caddy/Caddyfile.bak.$(date +%s)"
  cat > /etc/caddy/Caddyfile <<EOF
${DOMAIN} {
	handle ${WS_PATH} {
		reverse_proxy 127.0.0.1:${XRAY_PORT}
	}
	handle {
		respond "Not Found" 404
	}
}
EOF
  systemctl enable caddy >/dev/null 2>&1
  systemctl restart caddy
  sleep 2
  systemctl is-active --quiet caddy || die "Caddy 启动失败，请查看：journalctl -u caddy -n 50"
fi

# ---------- 防火墙（仅当 ufw 已启用时放行）----------
if command -v ufw >/dev/null && ufw status | grep -q "Status: active"; then
  if [[ -n "$DOMAIN" ]]; then
    ufw allow 80/tcp >/dev/null; ufw allow 443/tcp >/dev/null
  else
    ufw allow "${PORT}/tcp" >/dev/null
  fi
fi

# ---------- 生成 Clash Mihomo 节点 ----------
NODE=$(
  echo 'proxies:'
  echo "  - name: \"${NODE_NAME}\""
  echo '    type: vmess'
  echo "    server: ${SERVER}"
  echo "    port: ${CLIENT_PORT}"
  echo "    uuid: ${UUID}"
  echo '    alterId: 0'
  echo '    cipher: auto'
  echo '    udp: true'
  if [[ -n "$DOMAIN" ]]; then
    echo '    tls: true'
    echo "    servername: ${DOMAIN}"
    echo '    skip-cert-verify: false'
  fi
  echo '    network: ws'
  echo '    ws-opts:'
  echo "      path: ${WS_PATH}"
  if [[ -n "$DOMAIN" ]]; then
    echo '      headers:'
    echo "        Host: ${DOMAIN}"
  fi
)
echo "$NODE" > "$OUT_FILE"

echo
info "安装完成！Clash Mihomo 节点配置如下（已保存到 ${OUT_FILE}）："
echo "------------------------------------------------------------"
echo "$NODE"
echo "------------------------------------------------------------"
if [[ -z "$DOMAIN" ]]; then
  warn "请确认云服务商安全组/防火墙已放行 TCP ${PORT}"
else
  warn "请确认安全组已放行 TCP 80 和 443"
fi
