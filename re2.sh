#!/usr/bin/env bash
# ============================================================
#  代理协议一键安装脚本
#  支持：
#    [1] VLESS + TCP + XTLS-Vision + REALITY（Xray-core）
#    [2] Hysteria 2（ACME 自动证书 / 自签名证书）
#  支持系统：Ubuntu 20.04/22.04/24.04 | Debian 10/11/12
#            CentOS / Rocky / AlmaLinux（仅 Hysteria 2）
# ============================================================

set -euo pipefail

# ════════════════════════════════════════════════════════════
#  颜色 & 输出辅助
# ════════════════════════════════════════════════════════════
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
CYAN='\033[0;36m'; BOLD='\033[1m'; DIM='\033[2m'; NC='\033[0m'

info()  { echo -e "${GREEN}[INFO]${NC}  $*"; }
warn()  { echo -e "${YELLOW}[WARN]${NC}  $*"; }
error() { echo -e "${RED}[ERROR]${NC} $*"; exit 1; }
step()  { echo -e "\n${BOLD}${CYAN}▶  $*${NC}"; }
hr()    { echo -e "${DIM}──────────────────────────────────────────────────────${NC}"; }

# Install a stable command so the script can be started with: proxy
PROXY_COMMAND="/usr/local/bin/proxy"
PROXY_SCRIPT_DIR="/usr/local/lib/proxy"
PROXY_SCRIPT="${PROXY_SCRIPT_DIR}/re.sh"

install_proxy_command() {
    local source_script="${BASH_SOURCE[0]}"
    source_script="$(readlink -f "$source_script" 2>/dev/null || true)"

    if [[ -f "$source_script" && "$source_script" != "$PROXY_SCRIPT" ]]; then
        install -d -m 755 "$PROXY_SCRIPT_DIR"
        install -m 755 "$source_script" "$PROXY_SCRIPT"
    fi

    if [[ ! -f "$PROXY_SCRIPT" ]]; then
        warn "无法安装 proxy 快捷命令：当前脚本不是可读取的文件"
        return 0
    fi

    cat > "$PROXY_COMMAND" <<'PROXY_WRAPPER'
#!/usr/bin/env bash
exec /usr/local/lib/proxy/re.sh "$@"
PROXY_WRAPPER
    chmod 755 "$PROXY_COMMAND"
    info "快捷命令已就绪：现在可以直接输入 proxy 运行此脚本"
}

box() {
    local title="$*"
    local len=${#title}
    local pad=$(( (54 - len) / 2 ))
    echo ""
    echo -e "${BOLD}${CYAN}╔══════════════════════════════════════════════════════╗${NC}"
    printf "${BOLD}${CYAN}║%*s%s%*s║${NC}\n" $pad "" "$title" $(( 54 - len - pad )) ""
    echo -e "${BOLD}${CYAN}╚══════════════════════════════════════════════════════╝${NC}"
}

# ════════════════════════════════════════════════════════════
#  必须 root
# ════════════════════════════════════════════════════════════
[[ $EUID -ne 0 ]] && error "请使用 root 用户运行此脚本，或使用 sudo bash $0"
install_proxy_command

# ════════════════════════════════════════════════════════════
#  主菜单：选择协议
# ════════════════════════════════════════════════════════════
show_main_menu() {
    while true; do
    clear
    echo -e "${BOLD}${CYAN}"
    echo "  ╔══════════════════════════════════════════════════════╗"
    echo "  ║            代理协议一键安装脚本                      ║"
    echo "  ╚══════════════════════════════════════════════════════╝"
    echo -e "${NC}"
    echo "  请选择要安装的协议："
    echo ""
    echo "    [1]  VLESS + TCP + XTLS-Vision + REALITY"
    echo "         (Xray-core，抗检测，推荐)"
    echo ""
    echo "    [2]  Hysteria 2"
    echo "         (基于 QUIC，高速，支持 ACME 证书 / 自签名)"
    echo ""
    echo "    [3]  查看当前已有节点配置"
    echo ""
    echo "    [0]  退出"
    echo ""
    read -rp "  请输入 [0/1/2/3]（默认 1）: " PROTO_CHOICE
    PROTO_CHOICE=${PROTO_CHOICE:-1}
    case "$PROTO_CHOICE" in
        1) install_reality; return ;;
        2) install_hysteria2; return ;;
        3) show_existing_configs ;;
        0) echo ""; info "已退出。"; exit 0 ;;
        *) warn "无效选项，请重新运行脚本"; exit 1 ;;
    esac
    done
}

# Show the current server-side configuration instead of relying on values
# from the last installation run.
show_xray_existing_config() {
    local config="/usr/local/etc/xray/config.json"
    [[ -f "$config" ]] || return 1

    box "当前 Xray REALITY 节点"
    echo -e "  ${BOLD}配置文件${NC}: ${CYAN}${config}${NC}"

    if ! command -v jq &>/dev/null; then
        warn "未找到 jq，无法提取摘要，以下显示原始配置文件"
        sed -n '1,260p' "$config"
        return 0
    fi

    local port uuid sni target short_id private_key public_key server_ip status
    local info_file="/root/xray_reality_client.txt"
    local xray_bin="${XRAY_BIN:-/usr/local/bin/xray}"
    port=$(jq -r '.inbounds[0].port // empty' "$config" 2>/dev/null || true)
    uuid=$(jq -r '.inbounds[0].settings.clients[0].id // empty' "$config" 2>/dev/null || true)
    sni=$(jq -r '.inbounds[0].streamSettings.realitySettings.serverNames[0] // empty' "$config" 2>/dev/null || true)
    target=$(jq -r '.inbounds[0].streamSettings.realitySettings.target // empty' "$config" 2>/dev/null || true)
    short_id=$(jq -r '.inbounds[0].streamSettings.realitySettings.shortIds[0] // empty' "$config" 2>/dev/null || true)
    private_key=$(jq -r '.inbounds[0].streamSettings.realitySettings.privateKey // empty' "$config" 2>/dev/null || true)

    # Derive the current public key from the current private key when possible.
    if [[ -n "$private_key" && -x "$xray_bin" ]]; then
        local x25519_output
        x25519_output=$("$xray_bin" x25519 -i "$private_key" 2>/dev/null || true)
        public_key=$(printf '%s\n' "$x25519_output" \
            | awk -F': *' '/(PublicKey|Password):/ {print $2; exit}')
    fi
    if [[ -z "${public_key:-}" && -f "$info_file" ]]; then
        public_key=$(sed -nE 's/.*pbk\)[[:space:]]*:[[:space:]]*//p' "$info_file" | head -1)
    fi

    if systemctl is-active --quiet xray 2>/dev/null; then
        status="运行中"
    else
        status="未运行"
    fi
    printf "  ${BOLD}服务状态${NC}: %s\n" "$status"
    printf "  ${BOLD}端口${NC}:       %s\n" "${port:-未知}"
    printf "  ${BOLD}UUID${NC}:        %s\n" "${uuid:-未知}"
    printf "  ${BOLD}SNI${NC}:         %s\n" "${sni:-未知}"
    printf "  ${BOLD}伪装目标${NC}:    %s\n" "${target:-未知}"
    printf "  ${BOLD}ShortId${NC}:     %s\n" "${short_id:-未知}"
    [[ -n "${public_key:-}" ]] && printf "  ${BOLD}公钥 (pbk)${NC}:  %s\n" "$public_key"

    if [[ -f "$info_file" ]]; then
        echo -e "  ${BOLD}安装时信息${NC}:  ${CYAN}${info_file}${NC}"
    fi

    local server_ipv4 server_ipv6
    server_ipv4=$(hy2_get_ipv4 2>/dev/null || true)
    server_ipv6=$(hy2_get_ipv6 2>/dev/null || true)
    if [[ ( -n "$server_ipv4" || -n "$server_ipv6" ) && -n "${public_key:-}" && -n "$port" && -n "$uuid" && -n "$sni" && -n "$short_id" ]]; then
        local link_v4="" link_v6=""
        [[ -n "$server_ipv4" ]] && link_v4="vless://${uuid}@${server_ipv4}:${port}?encryption=none&flow=xtls-rprx-vision&security=reality&sni=${sni}&fp=chrome&pbk=${public_key}&sid=${short_id}&type=raw&headerType=none#REALITY-${server_ipv4}"
        [[ -n "$server_ipv6" ]] && link_v6="vless://${uuid}@[${server_ipv6}]:${port}?encryption=none&flow=xtls-rprx-vision&security=reality&sni=${sni}&fp=chrome&pbk=${public_key}&sid=${short_id}&type=raw&headerType=none#REALITY-v6-${server_ipv6}"

        echo ""
        echo -e "  ${BOLD}${GREEN}当前配置生成的 VLESS 分享链接:${NC}"
        if [[ -n "$link_v4" ]]; then
            echo -e "  ${DIM}[IPv4]${NC}"
            echo "  ${link_v4}"
        fi
        if [[ -n "$link_v6" ]]; then
            echo -e "  ${DIM}[IPv6]${NC}"
            echo "  ${link_v6}"
        fi

        if command -v qrencode &>/dev/null; then
            echo ""
            if [[ -n "$link_v4" ]]; then
                echo -e "  ${CYAN}${BOLD}二维码 (IPv4)：${NC}"
                qrencode -t ansiutf8 "${link_v4}"
            fi
            if [[ -n "$link_v6" ]]; then
                echo -e "  ${CYAN}${BOLD}二维码 (IPv6)：${NC}"
                qrencode -t ansiutf8 "${link_v6}"
            fi
        else
            warn "未安装 qrencode，无法显示二维码（可运行: apt-get install -y qrencode）"
        fi
    else
        warn "未能生成完整分享链接，请查看 ${info_file} 或手动填写服务器公网 IP"
    fi
}

show_hy2_existing_config() {
    local config="${HY2_CONF:-/etc/hysteria/config.yaml}"
    [[ -f "$config" ]] || return 1

    box "当前 Hysteria 2 节点"
    echo -e "  ${BOLD}配置文件${NC}: ${CYAN}${config}${NC}"

    local port="" password="" domain="" email="" ca=""
    local tls_mode="" server_ipv4="" server_ipv6=""
    local cert_file="" sni="" status
    port=$(sed -nE 's/^listen:[[:space:]]*:([0-9]+).*$/\1/p' "$config" | head -1)
    password=$(sed -nE 's/^[[:space:]]*password:[[:space:]]*"?([^"]*)"?[[:space:]]*$/\1/p' "$config" | head -1)
    email=$(sed -nE 's/^[[:space:]]*email:[[:space:]]*//p' "$config" | head -1)
    ca=$(sed -nE 's/^[[:space:]]*ca:[[:space:]]*//p' "$config" | head -1)

    if grep -q '^acme:' "$config"; then
        tls_mode="ACME"
        domain=$(awk '
            /^acme:/ { in_acme=1; next }
            in_acme && /^[^[:space:]]/ { exit }
            in_acme && /^[[:space:]]*-[[:space:]]/ {
                sub(/^[[:space:]]*-[[:space:]]*/, ""); print; exit
            }
        ' "$config")
        cert_file=$(find "${HY2_ACME_DIR:-/etc/hysteria/acme}" -type f -name '*.crt' ! -name '*issuer*' -print -quit 2>/dev/null || true)
    else
        tls_mode="自签名"
        cert_file="${HY2_CERT_DIR:-/etc/hysteria/certs}/server.crt"
    fi

    if [[ -n "$cert_file" && -f "$cert_file" ]]; then
        sni=$(openssl x509 -in "$cert_file" -noout -subject -nameopt RFC2253 2>/dev/null \
            | sed -nE 's/^subject=.*CN=([^,]+).*$/\1/p')
    fi

    if systemctl is-active --quiet hysteria-server 2>/dev/null; then
        status="运行中"
    else
        status="未运行"
    fi
    printf "  ${BOLD}服务状态${NC}: %s\n" "$status"
    printf "  ${BOLD}端口${NC}:       %s\n" "${port:-未知}"
    printf "  ${BOLD}认证密码${NC}:   %s\n" "${password:-未知}"
    printf "  ${BOLD}TLS 模式${NC}:   %s\n" "$tls_mode"
    [[ -n "$domain" ]] && printf "  ${BOLD}域名${NC}:       %s\n" "$domain"
    [[ -n "$sni" ]] && printf "  ${BOLD}SNI${NC}:         %s\n" "$sni"
    [[ -n "$email" ]] && printf "  ${BOLD}ACME 邮箱${NC}:  %s\n" "$email"
    [[ -n "$ca" ]] && printf "  ${BOLD}ACME CA${NC}:    %s\n" "$ca"
    [[ -n "$cert_file" ]] && printf "  ${BOLD}证书${NC}:       %s\n" "$cert_file"

    server_ipv4=$(hy2_get_ipv4 2>/dev/null || true)
    server_ipv6=$(hy2_get_ipv6 2>/dev/null || true)
    echo ""
    _FP_B64=""
    if [[ "$tls_mode" == "自签名" && -f "$cert_file" ]]; then
        hy2_print_cert_fingerprints "$cert_file"
    fi

    local host="" encoded_fp="" addr
    local -a qr_links=()
    if [[ "$tls_mode" == "ACME" ]]; then
        host="$domain"
        if [[ -n "$host" ]]; then
            local link="hysteria2://${password}@${host}:${port}#HY2-VPS"
            echo "$link"
            qr_links+=("$link")
        fi
    elif [[ -n "${_FP_B64:-}" ]]; then
        encoded_fp=$(printf '%s' "$_FP_B64" | sed 's/+/%2B/g;s|/|%2F|g;s/=/%3D/g')
        for addr in "$server_ipv4" "$server_ipv6"; do
            [[ -z "$addr" ]] && continue
            [[ "$addr" == *:* ]] && host="[${addr}]" || host="$addr"
            local link="hysteria2://${password}@${host}:${port}?insecure=0&sni=${sni}&pinSHA256=${encoded_fp}#HY2-VPS-${addr}"
            echo "$link"
            qr_links+=("$link")
        done
    else
        warn "未找到证书指纹，无法生成自签名模式分享链接"
    fi

    if (( ${#qr_links[@]} > 0 )); then
        if command -v qrencode &>/dev/null; then
            echo ""
            local i=0
            for link in "${qr_links[@]}"; do
                (( i++ ))
                echo -e "  ${CYAN}${BOLD}二维码 (${i})：${NC}"
                qrencode -t ansiutf8 "${link}"
            done
        else
            warn "未安装 qrencode，无法显示二维码（可运行: apt-get install -y qrencode）"
        fi
    fi

    echo ""
    echo -e "  ${BOLD}原始配置（前 80 行）:${NC}"
    sed -n '1,80p' "$config"
}

show_existing_configs() {
    clear
    box "查看当前已有节点配置"
    local found=0

    if show_xray_existing_config; then
        found=1
    fi
    if show_hy2_existing_config; then
        found=1
    fi
    if (( found == 0 )); then
        warn "未找到本脚本创建的 Xray 或 Hysteria 2 配置"
        echo ""
        echo "  Xray 配置: /usr/local/etc/xray/config.json"
        echo "  Hysteria 2 配置: /etc/hysteria/config.yaml"
    fi

    echo ""
    read -rp "按回车返回主菜单..." _
}


# ╔══════════════════════════════════════════════════════════╗
# ║         PART 1 — VLESS + XTLS-Vision + REALITY          ║
# ╚══════════════════════════════════════════════════════════╝

# ────────────────────────────────────────────────────────────
#  检测系统（仅 Ubuntu / Debian）
# ────────────────────────────────────────────────────────────
re_detect_os() {
    if [[ -f /etc/os-release ]]; then
        source /etc/os-release
        OS_ID="${ID}"
        OS_VER="${VERSION_ID}"
    else
        error "无法检测操作系统，仅支持 Ubuntu/Debian"
    fi
    case "${OS_ID}" in
        ubuntu|debian) info "检测到系统：${OS_ID} ${OS_VER}" ;;
        *) error "REALITY 脚本仅支持 Ubuntu / Debian，当前系统：${OS_ID}" ;;
    esac
}

# ────────────────────────────────────────────────────────────
#  安装依赖（REALITY）
# ────────────────────────────────────────────────────────────
re_install_deps() {
    step "安装依赖"
    apt-get update -qq
    apt-get install -y -qq curl wget unzip jq qrencode 2>/dev/null || \
        apt-get install -y -qq curl wget unzip jq
    info "依赖安装完成"
}

# ────────────────────────────────────────────────────────────
#  安装 Xray-core
# ────────────────────────────────────────────────────────────
re_install_xray() {
    step "安装 Xray-core"
    XRAY_BIN="/usr/local/bin/xray"

    info "获取最新版本信息..."
    LATEST_VERSION="$(curl -sI "https://github.com/XTLS/Xray-core/releases/latest" \
        | grep -i "^location:" | grep -oE "v[0-9]+\.[0-9]+\.[0-9]+" | head -1)"
    [[ "${LATEST_VERSION}" =~ ^v[0-9] ]] || LATEST_VERSION="v25.3.6"
    info "最新版本：${LATEST_VERSION}"

    ARCH="$(uname -m)"
    case "${ARCH}" in
        x86_64)           ARCH_STR="64" ;;
        aarch64|arm64)    ARCH_STR="arm64-v8a" ;;
        armv7l)           ARCH_STR="arm32-v7a" ;;
        *)                error "不支持的架构：${ARCH}" ;;
    esac

    DOWNLOAD_URL="https://github.com/XTLS/Xray-core/releases/download/${LATEST_VERSION}/Xray-linux-${ARCH_STR}.zip"
    info "下载地址：${DOWNLOAD_URL}"

    TMP_DIR="$(mktemp -d)"
    curl -sL --retry 3 -o "${TMP_DIR}/xray.zip" "${DOWNLOAD_URL}" \
        || error "下载失败，请检查网络连接"

    unzip -qo "${TMP_DIR}/xray.zip" -d "${TMP_DIR}/"
    install -m 755 "${TMP_DIR}/xray" "${XRAY_BIN}"
    rm -rf "${TMP_DIR}"

    mkdir -p /usr/local/share/xray
    curl -sL --retry 3 -o /usr/local/share/xray/geoip.dat \
        "https://github.com/v2fly/geoip/releases/latest/download/geoip.dat" \
        || warn "geoip.dat 下载失败（可忽略）"
    curl -sL --retry 3 -o /usr/local/share/xray/geosite.dat \
        "https://github.com/v2fly/domain-list-community/releases/latest/download/dlc.dat" \
        || warn "geosite.dat 下载失败（可忽略）"

    mkdir -p /usr/local/etc/xray /var/log/xray
    cat > /etc/systemd/system/xray.service <<'SYSTEMD'
[Unit]
Description=Xray Service
Documentation=https://github.com/xtls
After=network.target nss-lookup.target

[Service]
User=root
CapabilityBoundingSet=CAP_NET_ADMIN CAP_NET_BIND_SERVICE
AmbientCapabilities=CAP_NET_ADMIN CAP_NET_BIND_SERVICE
NoNewPrivileges=true
ExecStart=/usr/local/bin/xray run -config /usr/local/etc/xray/config.json
Restart=on-failure
RestartPreventExitStatus=23
LimitNPROC=10000
LimitNOFILE=1000000

[Install]
WantedBy=multi-user.target
SYSTEMD

    systemctl daemon-reload
    [[ -x "${XRAY_BIN}" ]] || error "Xray 安装失败"
    info "Xray 安装成功：$("${XRAY_BIN}" version | head -1)"
}

# ────────────────────────────────────────────────────────────
#  生成密钥材料
# ────────────────────────────────────────────────────────────
re_gen_keys() {
    step "生成密钥材料"

    RE_UUID="$("${XRAY_BIN}" uuid)"
    info "UUID：${RE_UUID}"

    KEY_PAIR="$("${XRAY_BIN}" x25519)"
    RE_PRIVATE_KEY="$(echo "${KEY_PAIR}" | grep 'PrivateKey:'         | awk '{print $2}')"
    RE_PUBLIC_KEY="$(echo "${KEY_PAIR}"  | grep -i 'Password\|PublicKey' | awk '{print $NF}')"
    info "私钥：${RE_PRIVATE_KEY}"
    info "公钥：${RE_PUBLIC_KEY}"

    RE_SHORT_ID="$(openssl rand -hex 8)"
    info "ShortId：${RE_SHORT_ID}"
}

# ────────────────────────────────────────────────────────────
#  交互式配置
# ────────────────────────────────────────────────────────────
re_interactive_config() {
    step "交互式配置"

    read -rp "$(echo -e "${CYAN}请输入监听端口 [默认 443]：${NC}")" INPUT_PORT
    RE_PORT="${INPUT_PORT:-443}"

    echo -e "${YELLOW}提示：target 是 REALITY 伪装的目标网站（需支持 TLSv1.3 + H2，且 IP 不在 CDN 上）${NC}"
    echo -e "${YELLOW}推荐选项：dl.google.com | www.microsoft.com | addons.mozilla.org | cdn.jsdelivr.net${NC}"
    read -rp "$(echo -e "${CYAN}请输入伪装目标 [默认 dl.google.com]：${NC}")" INPUT_TARGET
    RE_TARGET_HOST="${INPUT_TARGET:-dl.google.com}"
    RE_TARGET="${RE_TARGET_HOST}:443"

    read -rp "$(echo -e "${CYAN}请输入 serverName [默认 ${RE_TARGET_HOST}]：${NC}")" INPUT_SNI
    RE_SERVER_NAME="${INPUT_SNI:-${RE_TARGET_HOST}}"
}

# ────────────────────────────────────────────────────────────
#  写入 Xray 服务端配置
# ────────────────────────────────────────────────────────────
re_write_config() {
    step "写入服务端配置"
    mkdir -p /usr/local/etc/xray

    cat > /usr/local/etc/xray/config.json <<EOF
{
  "log": {
    "loglevel": "warning"
  },
  "routing": {
    "domainStrategy": "IPIfNonMatch",
    "rules": [
      {
        "type": "field",
        "ip": ["geoip:private"],
        "outboundTag": "block"
      },
      {
        "type": "field",
        "ip": ["geoip:cn"],
        "outboundTag": "block"
      },
      {
        "type": "field",
        "domain": ["geosite:cn", "geosite:private"],
        "outboundTag": "block"
      }
    ]
  },
  "inbounds": [
    {
      "listen": "::",
      "port": ${RE_PORT},
      "protocol": "vless",
      "settings": {
        "clients": [
          {
            "id": "${RE_UUID}",
            "flow": "xtls-rprx-vision"
          }
        ],
        "decryption": "none"
      },
      "streamSettings": {
        "network": "raw",
        "security": "reality",
        "realitySettings": {
          "show": false,
          "target": "${RE_TARGET}",
          "xver": 0,
          "serverNames": [
            "${RE_SERVER_NAME}"
          ],
          "privateKey": "${RE_PRIVATE_KEY}",
          "maxTimeDiff": 70000,
          "shortIds": [
            "${RE_SHORT_ID}",
            ""
          ]
        }
      },
      "sniffing": {
        "enabled": true,
        "destOverride": ["http", "tls", "quic"]
      }
    }
  ],
  "outbounds": [
    {
      "protocol": "freedom",
      "tag": "direct",
      "settings": {
        "domainStrategy": "UseIPv4"
      }
    },
    {
      "protocol": "blackhole",
      "tag": "block"
    }
  ]
}
EOF
    info "配置文件已写入 /usr/local/etc/xray/config.json"
}

# ────────────────────────────────────────────────────────────
#  配置防火墙
# ────────────────────────────────────────────────────────────
re_configure_firewall() {
    step "配置防火墙"
    if command -v ufw &>/dev/null && ufw status | grep -q "Status: active"; then
        ufw allow "${RE_PORT}/tcp" comment "Xray REALITY"
        info "ufw 已放行端口 ${RE_PORT}/tcp"
    elif command -v iptables &>/dev/null; then
        iptables -I INPUT -p tcp --dport "${RE_PORT}" -j ACCEPT 2>/dev/null || true
        info "iptables 已放行端口 ${RE_PORT}/tcp (IPv4)"
        if command -v ip6tables &>/dev/null; then
            ip6tables -I INPUT -p tcp --dport "${RE_PORT}" -j ACCEPT 2>/dev/null || true
            info "ip6tables 已放行端口 ${RE_PORT}/tcp (IPv6)"
        else
            warn "未检测到 ip6tables，若服务器有公网 IPv6，请手动放行 IPv6 的 ${RE_PORT}/tcp"
        fi
    else
        warn "未检测到防火墙，请手动放行端口 ${RE_PORT}"
    fi
}

# ────────────────────────────────────────────────────────────
#  启动 Xray 服务
# ────────────────────────────────────────────────────────────
re_start_xray() {
    step "启动 Xray 服务"
    systemctl daemon-reload
    systemctl enable xray
    systemctl restart xray
    sleep 2
    if systemctl is-active --quiet xray; then
        info "Xray 服务运行正常 ✔"
    else
        error "Xray 服务启动失败，请执行 journalctl -u xray -n 50 查看日志"
    fi
}

# ────────────────────────────────────────────────────────────
#  输出客户端配置
# ────────────────────────────────────────────────────────────
re_print_client_info() {
    local server_ipv4=$1
    local server_ipv6=${2:-}
    step "客户端配置信息"

    # IPv6 地址在 URI 中需要用中括号包裹
    local link_v4="" link_v6=""
    [[ -n "$server_ipv4" ]] && link_v4="vless://${RE_UUID}@${server_ipv4}:${RE_PORT}?encryption=none&flow=xtls-rprx-vision&security=reality&sni=${RE_SERVER_NAME}&fp=chrome&pbk=${RE_PUBLIC_KEY}&sid=${RE_SHORT_ID}&type=raw&headerType=none#REALITY-${server_ipv4}"
    [[ -n "$server_ipv6" ]] && link_v6="vless://${RE_UUID}@[${server_ipv6}]:${RE_PORT}?encryption=none&flow=xtls-rprx-vision&security=reality&sni=${RE_SERVER_NAME}&fp=chrome&pbk=${RE_PUBLIC_KEY}&sid=${RE_SHORT_ID}&type=raw&headerType=none#REALITY-v6-${server_ipv6}"

    echo -e "${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    [[ -n "$server_ipv4" ]] && echo -e "${BOLD}服务器地址(v4):${NC} ${server_ipv4}"
    [[ -n "$server_ipv6" ]] && echo -e "${BOLD}服务器地址(v6):${NC} ${server_ipv6}"
    echo -e "${BOLD}端口         :${NC} ${RE_PORT}"
    echo -e "${BOLD}协议         :${NC} vless"
    echo -e "${BOLD}UUID         :${NC} ${RE_UUID}"
    echo -e "${BOLD}Flow         :${NC} xtls-rprx-vision"
    echo -e "${BOLD}传输方式     :${NC} raw (TCP)"
    echo -e "${BOLD}安全         :${NC} reality"
    echo -e "${BOLD}SNI          :${NC} ${RE_SERVER_NAME}"
    echo -e "${BOLD}指纹         :${NC} chrome"
    echo -e "${BOLD}公钥 (pbk)   :${NC} ${RE_PUBLIC_KEY}"
    echo -e "${BOLD}ShortId      :${NC} ${RE_SHORT_ID}"
    echo -e "${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo ""
    echo -e "${CYAN}${BOLD}▶ 分享链接（可直接导入 v2rayN / NekoBox / Shadowrocket 等客户端）：${NC}"
    if [[ -n "$link_v4" ]]; then
        echo -e "  ${DIM}[IPv4]${NC}"
        echo -e "  ${GREEN}${link_v4}${NC}"
    fi
    if [[ -n "$link_v6" ]]; then
        echo -e "  ${DIM}[IPv6]${NC}"
        echo -e "  ${GREEN}${link_v6}${NC}"
    fi
    echo ""

    if command -v qrencode &>/dev/null; then
        if [[ -n "$link_v4" ]]; then
            echo -e "${CYAN}${BOLD}▶ 二维码 (IPv4)：${NC}"
            qrencode -t ansiutf8 "${link_v4}"
        fi
        if [[ -n "$link_v6" ]]; then
            echo -e "${CYAN}${BOLD}▶ 二维码 (IPv6)：${NC}"
            qrencode -t ansiutf8 "${link_v6}"
        fi
    fi

    local info_file="/root/xray_reality_client.txt"
    cat > "${info_file}" <<EOF
VLESS + REALITY 客户端配置
========================================
服务器地址(v4) : ${server_ipv4:-无}
服务器地址(v6) : ${server_ipv6:-无}
端口       : ${RE_PORT}
UUID       : ${RE_UUID}
Flow       : xtls-rprx-vision
传输方式   : raw (TCP)
安全       : reality
SNI        : ${RE_SERVER_NAME}
指纹       : chrome
公钥 (pbk) : ${RE_PUBLIC_KEY}
ShortId    : ${RE_SHORT_ID}

分享链接：
$( [[ -n "$link_v4" ]] && echo "[IPv4] ${link_v4}" )
$( [[ -n "$link_v6" ]] && echo "[IPv6] ${link_v6}" )

服务管理命令：
  查看状态  : systemctl status xray
  重启服务  : systemctl restart xray
  查看日志  : journalctl -u xray -f
  配置文件  : /usr/local/etc/xray/config.json
EOF
    info "客户端配置已保存至 ${info_file}"
}

# ────────────────────────────────────────────────────────────
#  REALITY 主流程入口
# ────────────────────────────────────────────────────────────
install_reality() {
    clear
    echo -e "${CYAN}${BOLD}"
    echo "  ██╗  ██╗██████╗  █████╗ ██╗   ██╗    ██████╗ ███████╗ █████╗ ██╗     ██╗████████╗██╗   ██╗"
    echo "  ╚██╗██╔╝██╔══██╗██╔══██╗╚██╗ ██╔╝    ██╔══██╗██╔════╝██╔══██╗██║     ██║╚══██╔══╝╚██╗ ██╔╝"
    echo "   ╚███╔╝ ██████╔╝███████║ ╚████╔╝     ██████╔╝█████╗  ███████║██║     ██║   ██║    ╚████╔╝ "
    echo "   ██╔██╗ ██╔══██╗██╔══██║  ╚██╔╝      ██╔══██╗██╔══╝  ██╔══██║██║     ██║   ██║     ╚██╔╝  "
    echo "  ██╔╝ ██╗██║  ██║██║  ██║   ██║       ██║  ██║███████╗██║  ██║███████╗██║   ██║      ██║   "
    echo "  ╚═╝  ╚═╝╚═╝  ╚═╝╚═╝  ╚═╝   ╚═╝       ╚═╝  ╚═╝╚══════╝╚═╝  ╚═╝╚══════╝╚═╝   ╚═╝      ╚═╝  "
    echo -e "${NC}"
    echo -e "  ${BOLD}VLESS + TCP + XTLS-Vision + REALITY 一键安装脚本${NC}"
    echo -e "  基于 XTLS/Xray-core 官方最新版本\n"

    re_detect_os
    re_install_deps
    re_install_xray
    re_gen_keys
    re_interactive_config
    re_write_config
    re_configure_firewall
    re_start_xray

    # 获取公网 IP（服务已启动完毕后），IPv4/IPv6 都探测
    local server_ipv4 server_ipv6
    server_ipv4=$(hy2_get_ipv4)
    server_ipv6=$(hy2_get_ipv6)
    [[ -n "$server_ipv4" ]] && info "服务器公网 IPv4：${server_ipv4}" || warn "未检测到公网 IPv4"
    [[ -n "$server_ipv6" ]] && info "服务器公网 IPv6：${server_ipv6}" || info "未检测到公网 IPv6（单栈服务器）"

    if [[ -z "$server_ipv4" && -z "$server_ipv6" ]]; then
        server_ipv4="YOUR_SERVER_IP"
    fi

    re_print_client_info "${server_ipv4}" "${server_ipv6}"

    echo ""
    info "✅ REALITY 安装完成！请将上方配置信息导入客户端。"
    echo ""
}


# ╔══════════════════════════════════════════════════════════╗
# ║                  PART 2 — Hysteria 2                    ║
# ╚══════════════════════════════════════════════════════════╝

HY2_BIN="/usr/local/bin/hysteria"
HY2_CONF_DIR="/etc/hysteria"
HY2_CONF="${HY2_CONF_DIR}/config.yaml"
HY2_SERVICE="/etc/systemd/system/hysteria-server.service"
HY2_CERT_DIR="${HY2_CONF_DIR}/certs"
HY2_ACME_DIR="${HY2_CONF_DIR}/acme"

# 全局：证书指纹（供 URI 使用）
_FP_B64=""
_FP_COLON=""

# ────────────────────────────────────────────────────────────
#  检测是否已安装
# ────────────────────────────────────────────────────────────
hy2_is_installed() {
    [[ -f "$HY2_BIN" ]] || systemctl list-unit-files hysteria-server.service &>/dev/null 2>&1
}

# ────────────────────────────────────────────────────────────
#  卸载 & 清理
# ────────────────────────────────────────────────────────────
hy2_do_uninstall() {
    step "卸载现有 Hysteria 2 并清理所有文件"

    systemctl stop    hysteria-server 2>/dev/null || true
    systemctl disable hysteria-server 2>/dev/null || true
    systemctl daemon-reload           2>/dev/null || true

    local targets=(
        "$HY2_BIN"
        "$HY2_SERVICE"
        "$HY2_CONF_DIR"
        "/var/log/hysteria"
    )
    for t in "${targets[@]}"; do
        [[ -e "$t" ]] && { info "删除 $t"; rm -rf "$t"; }
    done

    systemctl daemon-reload 2>/dev/null || true
    info "✅ 卸载清理完毕"
}

# ────────────────────────────────────────────────────────────
#  获取公网 IP
# ────────────────────────────────────────────────────────────
hy2_get_ipv4() {
    local ip
    ip=$(curl -4 -fsSL --max-time 6 https://api.ipify.org   2>/dev/null) ||
    ip=$(curl -4 -fsSL --max-time 6 https://ifconfig.me     2>/dev/null) ||
    ip=$(curl -4 -fsSL --max-time 6 https://icanhazip.com   2>/dev/null) ||
    ip=$(hostname -I | awk '{print $1}') || true
    echo "${ip}"
}

hy2_get_ipv6() {
    local ip
    ip=$(curl -6 -fsSL --max-time 6 https://api6.ipify.org  2>/dev/null) ||
    ip=$(curl -6 -fsSL --max-time 6 https://ifconfig.me     2>/dev/null) ||
    ip=$(curl -6 -fsSL --max-time 6 https://icanhazip.com   2>/dev/null) || true
    if [[ "$ip" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
        ip=""
    fi
    echo "${ip}"
}

# ────────────────────────────────────────────────────────────
#  CPU 架构 → hysteria 下载后缀
# ────────────────────────────────────────────────────────────
hy2_get_arch() {
    local m; m=$(uname -m)
    case "$m" in
        x86_64)
            grep -q avx /proc/cpuinfo 2>/dev/null && echo "amd64-avx" || echo "amd64" ;;
        aarch64|arm64)  echo "arm64"  ;;
        armv7*|armv6*)  echo "armv7"  ;;
        s390x)          echo "s390x"  ;;
        *)              error "不支持的 CPU 架构: $m" ;;
    esac
}

# ────────────────────────────────────────────────────────────
#  获取最新版本号
# ────────────────────────────────────────────────────────────
hy2_get_latest_version() {
    local v
    v=$(curl -fsSL --max-time 10 \
        "https://api.github.com/repos/apernet/hysteria/releases/latest" \
        | grep '"tag_name"' | sed -E 's/.*"([^"]+)".*/\1/')
    [[ -z "$v" ]] && error "无法获取最新版本，请检查网络"
    echo "$v"
}

# ────────────────────────────────────────────────────────────
#  安装系统依赖（Hysteria 2，支持 apt/dnf/yum）
# ────────────────────────────────────────────────────────────
#  低内存环境（如 96M 的 LXC 容器）辅助函数
#  在 LXC 中 swapon 常因宿主机限制而失败（Operation not permitted），
#  这里静默尝试，失败就跳过，不影响主流程。
HY2_TMP_SWAP="/swapfile_re_tmp"
hy2_try_swap() {
    command -v free &>/dev/null || return 0
    local swap_total_mb mem_total_mb
    swap_total_mb=$(free -m | awk '/^Swap:/{print $2+0; exit}')
    mem_total_mb=$(free -m | awk '/^Mem:/{print $2+0; exit}')

    (( swap_total_mb > 0 )) && return 0   # 已有 swap，不重复创建
    (( mem_total_mb > 400 )) && return 0  # 内存不算紧张，跳过

    [[ -f "$HY2_TMP_SWAP" ]] && return 0
    if (fallocate -l 100M "$HY2_TMP_SWAP" 2>/dev/null || dd if=/dev/zero of="$HY2_TMP_SWAP" bs=1M count=100 2>/dev/null) \
        && chmod 600 "$HY2_TMP_SWAP" \
        && mkswap "$HY2_TMP_SWAP" &>/dev/null \
        && swapon "$HY2_TMP_SWAP" &>/dev/null; then
        info "已启用临时 swap（100M），安装完成后将自动清理"
    else
        rm -f "$HY2_TMP_SWAP" 2>/dev/null || true
        warn "当前环境不支持创建 swap（常见于 LXC 容器），改为分批安装以降低内存占用"
    fi
}

hy2_cleanup_swap() {
    [[ -f "$HY2_TMP_SWAP" ]] || return 0
    swapoff "$HY2_TMP_SWAP" &>/dev/null || true
    rm -f "$HY2_TMP_SWAP"
}

# 单个包安装，带重试；失败时清一次 apt 缓存再试一次，降低内存/磁盘压力
hy2_apt_install_one() {
    local pkg="$1" required="${2:-1}" i
    command -v "$pkg" &>/dev/null && return 0   # 已存在同名命令，跳过（如 curl/openssl）

    for i in 1 2; do
        if DEBIAN_FRONTEND=noninteractive apt-get install -y "$pkg"; then
            return 0
        fi
        warn "安装 ${pkg} 失败（可能是内存不足被系统杀死），清理缓存后重试 (${i}/2)..."
        apt-get clean &>/dev/null || true
        dpkg --configure -a &>/dev/null || true
        sleep 2
    done

    if [[ "$required" == "1" ]]; then
        return 1
    else
        warn "${pkg} 安装失败，已跳过（非必需，脚本继续）"
        return 0
    fi
}

hy2_install_deps() {
    step "安装依赖（curl openssl xxd）"
    if command -v apt-get &>/dev/null; then
        hy2_try_swap

        local i update_ok=0
        for i in 1 2 3; do
            apt-get update -qq && { update_ok=1; break; }
            warn "apt-get update 失败，重试 (${i}/3)..."
            sleep 2
        done
        (( update_ok == 0 )) && warn "apt-get update 多次失败，尝试使用现有缓存继续安装"

        # 分开装，而不是一条命令装三个：单次内存峰值更低，
        # 某一个包被 OOM 杀死也不会连累其余两个。
        local fail=0
        hy2_apt_install_one curl    1 || fail=1
        hy2_apt_install_one openssl 1 || fail=1
        # xxd 属于 vim-common 包体，体积较大；装不上不影响核心功能，降级为非必需
        hy2_apt_install_one xxd     0 || true

        hy2_cleanup_swap

        if (( fail == 1 )); then
            local missing=()
            command -v curl    &>/dev/null || missing+=("curl")
            command -v openssl &>/dev/null || missing+=("openssl")
            error "依赖安装失败，仍缺少: ${missing[*]}。常见原因：内存不足被系统杀死 / 网络无法访问软件源 / 磁盘空间不足。可尝试手动执行: apt-get update && apt-get install -y ${missing[*]}"
        fi

        command -v xxd &>/dev/null && info "依赖已就绪：curl / openssl / xxd" \
            || warn "依赖已就绪：curl / openssl（xxd 缺失，若后续步骤报错缺少 xxd，可手动安装: apt-get install -y xxd）"
    elif command -v dnf &>/dev/null; then
        dnf install -y -q curl openssl vim-common 2>/dev/null || \
        dnf install -y -q curl openssl
    elif command -v yum &>/dev/null; then
        yum install -y -q curl openssl vim-common 2>/dev/null || \
        yum install -y -q curl openssl
    else
        warn "无法自动安装依赖，请确保 curl / openssl / xxd 已安装"
    fi
}

# ────────────────────────────────────────────────────────────
#  下载 Hysteria 2 二进制
# ────────────────────────────────────────────────────────────
hy2_download() {
    local version=$1 arch=$2
    local url="https://github.com/apernet/hysteria/releases/download/${version}/hysteria-linux-${arch}"
    step "下载 Hysteria 2 ${version} (${arch})"
    info "URL: ${url}"
    curl -fL --progress-bar -o "$HY2_BIN" "$url" \
        || error "下载失败，请检查网络连接或手动下载: ${url}"
    chmod +x "$HY2_BIN"
    info "✅ 二进制已安装至 ${HY2_BIN}"
}

# ────────────────────────────────────────────────────────────
#  生成自签名 TLS 证书
# ────────────────────────────────────────────────────────────
hy2_gen_selfsigned_cert() {
    local sni=$1
    step "生成自签名 TLS 证书（P-256，有效期 3650 天，SNI=${sni}）"
    mkdir -p "$HY2_CERT_DIR"
    local san="DNS:${sni}"
    openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:P-256 \
        -keyout "${HY2_CERT_DIR}/server.key" \
        -out    "${HY2_CERT_DIR}/server.crt" \
        -days 3650 -nodes \
        -subj "/CN=${sni}" \
        -addext "subjectAltName=${san}" \
        2>/dev/null || \
    openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:P-256 \
        -keyout "${HY2_CERT_DIR}/server.key" \
        -out    "${HY2_CERT_DIR}/server.crt" \
        -days 3650 -nodes \
        -subj "/CN=${sni}" \
        2>/dev/null
    chmod 600 "${HY2_CERT_DIR}/server.key"
    chmod 644 "${HY2_CERT_DIR}/server.crt"
    info "✅ 证书生成完毕（CN=${sni}，客户端须配置 sni: ${sni}）"
}

# ────────────────────────────────────────────────────────────
#  写入 config.yaml —— ACME 模式
# ────────────────────────────────────────────────────────────
hy2_write_config_acme() {
    local domain=$1 email=$2 password=$3 port=$4 ca=$5
    mkdir -p "$HY2_CONF_DIR" "$HY2_ACME_DIR"
    cat > "$HY2_CONF" <<EOF
listen: :${port}

acme:
  domains:
    - ${domain}
  email: ${email}
  ca: ${ca}
  dir: ${HY2_ACME_DIR}
  type: http

auth:
  type: password
  password: "${password}"

masquerade:
  type: proxy
  proxy:
    url: https://www.bing.com/
    rewriteHost: true
EOF
}

# ────────────────────────────────────────────────────────────
#  写入 config.yaml —— 自签名模式
# ────────────────────────────────────────────────────────────
hy2_write_config_selfsigned() {
    local password=$1 port=$2
    mkdir -p "$HY2_CONF_DIR"
    cat > "$HY2_CONF" <<EOF
listen: :${port}

tls:
  cert: ${HY2_CERT_DIR}/server.crt
  key:  ${HY2_CERT_DIR}/server.key

auth:
  type: password
  password: "${password}"

masquerade:
  type: proxy
  proxy:
    url: https://www.bing.com/
    rewriteHost: true
EOF
}

# ────────────────────────────────────────────────────────────
#  写入 systemd 服务单元
# ────────────────────────────────────────────────────────────
hy2_write_service() {
    cat > "$HY2_SERVICE" <<EOF
[Unit]
Description=Hysteria 2 Server
Documentation=https://v2.hysteria.network/
After=network.target nss-lookup.target

[Service]
Type=simple
User=root
WorkingDirectory=${HY2_CONF_DIR}
ExecStart=${HY2_BIN} server -c ${HY2_CONF}
Restart=on-failure
RestartSec=5s
LimitNOFILE=1048576

[Install]
WantedBy=multi-user.target
EOF
}

# ────────────────────────────────────────────────────────────
#  等待 ACME 证书申请完成
# ────────────────────────────────────────────────────────────
hy2_wait_for_acme_cert() {
    local max_wait=90
    info "等待 Hysteria 2 自动申请证书（最多 ${max_wait}s）..."
    local i=0
    while (( i < max_wait )); do
        local f
        f=$(find "${HY2_ACME_DIR}" -name "*.crt" ! -name "*issuer*" 2>/dev/null | head -1)
        if [[ -n "$f" ]]; then
            echo ""
            info "✅ 证书已就绪: $f"
            echo "$f"
            return 0
        fi
        sleep 2; (( i += 2 ))
        printf "."
    done
    echo ""
    return 1
}

# ────────────────────────────────────────────────────────────
#  hex → Base64
# ────────────────────────────────────────────────────────────
hy2_hex_to_b64() {
    local hex=$1
    if command -v xxd &>/dev/null; then
        echo "$hex" | xxd -r -p | base64 -w0
    elif command -v python3 &>/dev/null; then
        python3 -c "import sys,base64,binascii; \
            print(base64.b64encode(binascii.unhexlify(sys.stdin.read().strip())).decode())" <<< "$hex"
    else
        echo "（需要 xxd 或 python3）"
    fi
}

# ────────────────────────────────────────────────────────────
#  输出证书 SHA256 指纹（多格式）
# ────────────────────────────────────────────────────────────
hy2_print_cert_fingerprints() {
    local cert_file=$1
    if [[ ! -f "$cert_file" ]]; then
        warn "证书文件不存在，跳过指纹输出: $cert_file"
        return
    fi

    box "TLS 证书 SHA256 指纹"

    local fp_colon
    fp_colon=$(openssl x509 -in "$cert_file" -noout -fingerprint -sha256 2>/dev/null \
               | sed -E 's/.*(sha256[: ])//I;s/SHA256 Fingerprint=//I' \
               | tr '[:lower:]' '[:upper:]')

    local fp_hex
    fp_hex=$(echo "$fp_colon" | tr -d ':' | tr '[:upper:]' '[:lower:]')

    local fp_b64
    fp_b64=$(hy2_hex_to_b64 "$fp_hex")

    local fp_spki
    fp_spki=$(openssl x509 -in "$cert_file" -noout -pubkey 2>/dev/null \
              | openssl pkey -pubin -outform DER 2>/dev/null \
              | openssl dgst -sha256 -binary 2>/dev/null \
              | base64 -w0 2>/dev/null) || fp_spki="（计算失败，需 openssl 3.x）"

    echo ""
    printf "  ${BOLD}[格式1]${NC} 十六进制·冒号分隔·大写\n"
    printf "           ${DIM}（Wireshark / 浏览器证书详情 / openssl 原生）${NC}\n"
    echo   -e "           ${CYAN}${fp_colon}${NC}"
    echo ""

    printf "  ${BOLD}[格式2]${NC} 纯十六进制·小写·无分隔符\n"
    printf "           ${DIM}（脚本处理 / 某些工具直接粘贴）${NC}\n"
    echo   -e "           ${CYAN}${fp_hex}${NC}"
    echo ""

    printf "  ${BOLD}[格式3]${NC} Base64 编码\n"
    printf "           ${DIM}URI 参数中 pinSHA256 使用（需 URL encode），见 URI Scheme 规范${NC}\n"
    echo   -e "           ${CYAN}${fp_b64}${NC}"
    echo ""

    printf "  ${BOLD}[格式4]${NC} sha256/<Base64>\n"
    printf "           ${DIM}（部分客户端工具使用的完整格式）${NC}\n"
    echo   -e "           ${CYAN}sha256/${fp_b64}${NC}"
    echo ""

    printf "  ${BOLD}[格式5]${NC} SPKI SHA256 Base64\n"
    printf "           ${DIM}（Chromium / HTTP Public Key Pinning）${NC}\n"
    echo   -e "           ${CYAN}${fp_spki}${NC}"
    echo ""

    echo -e "  ${BOLD}${GREEN}★  客户端配置文件 pinSHA256 字段（官方格式）${NC}"
    printf "           ${DIM}冒号分隔大写十六进制，直接粘贴到客户端配置${NC}\n"
    echo   -e "           ${CYAN}${fp_colon}${NC}"

    hr

    echo -e "  ${BOLD}证书主体  :${NC} $(openssl x509 -in "$cert_file" -noout -subject 2>/dev/null | sed 's/subject=//')"
    echo -e "  ${BOLD}签发者    :${NC} $(openssl x509 -in "$cert_file" -noout -issuer  2>/dev/null | sed 's/issuer=//')"
    echo -e "  ${BOLD}有效期起  :${NC} $(openssl x509 -in "$cert_file" -noout -startdate 2>/dev/null | sed 's/notBefore=//')"
    echo -e "  ${BOLD}有效期止  :${NC} $(openssl x509 -in "$cert_file" -noout -enddate   2>/dev/null | sed 's/notAfter=//')"
    hr

    # 存储供 URI 使用
    _FP_B64="$fp_b64"
    _FP_COLON="$fp_colon"
}

# ────────────────────────────────────────────────────────────
#  输出客户端配置 & URI（Hysteria 2）
# ────────────────────────────────────────────────────────────
hy2_print_client_info() {
    local tls_mode=$1 domain=$2 password=$3 port=$4 sni=$5
    local server_ipv4=$6 server_ipv6=$7 version=$8
    local cert_file=$9

    box "安装完成！"
    echo ""

    hr
    echo -e "  ${BOLD}版本            :${NC} ${CYAN}${version}${NC}"
    [[ -n "$server_ipv4" ]] && echo -e "  ${BOLD}公网 IPv4       :${NC} ${CYAN}${server_ipv4}${NC}"
    [[ -n "$server_ipv6" ]] && echo -e "  ${BOLD}公网 IPv6       :${NC} ${CYAN}${server_ipv6}${NC}"
    echo -e "  ${BOLD}端口            :${NC} ${CYAN}${port}${NC}"
    if [[ "$tls_mode" == "1" ]]; then
        echo -e "  ${BOLD}域名            :${NC} ${CYAN}${domain}${NC}"
        echo -e "  ${BOLD}TLS 模式        :${NC} ${CYAN}ACME 自动证书${NC}"
    else
        echo -e "  ${BOLD}SNI（伪装域名）  :${NC} ${CYAN}${sni}${NC}"
        echo -e "  ${BOLD}TLS 模式        :${NC} ${CYAN}自签名证书${NC}"
    fi
    echo -e "  ${BOLD}密码            :${NC} ${CYAN}${password}${NC}"
    hr

    # ── 证书目录 ────────────────────────────────────────────
    echo ""
    echo -e "  ${BOLD}📁 证书目录${NC}"
    hr
    if [[ "$tls_mode" == "1" ]]; then
        echo -e "  根目录 : ${CYAN}${HY2_ACME_DIR}${NC}"
        echo -e "  证书   : ${CYAN}${HY2_ACME_DIR}/certificates/acme-v02.api.letsencrypt.org-directory/${domain}/${domain}.crt${NC}"
        echo -e "  私钥   : ${CYAN}${HY2_ACME_DIR}/certificates/acme-v02.api.letsencrypt.org-directory/${domain}/${domain}.key${NC}"
        [[ -n "$cert_file" ]] && echo -e "  实际检测到: ${CYAN}${cert_file}${NC}"
        echo -e "  ${DIM}  ✓ 全程自动管理，到期前 30 天自动续签${NC}"
    else
        echo -e "  目录   : ${CYAN}${HY2_CERT_DIR}/${NC}"
        echo -e "  证书   : ${CYAN}${HY2_CERT_DIR}/server.crt${NC}"
        echo -e "  私钥   : ${CYAN}${HY2_CERT_DIR}/server.key${NC}"
    fi
    hr

    # ── 证书指纹 ────────────────────────────────────────────
    if [[ -n "$cert_file" && -f "$cert_file" ]]; then
        hy2_print_cert_fingerprints "$cert_file"
    elif [[ "$tls_mode" == "2" && -f "${HY2_CERT_DIR}/server.crt" ]]; then
        hy2_print_cert_fingerprints "${HY2_CERT_DIR}/server.crt"
    else
        echo ""
        warn "ACME 证书尚未生成，证书就绪后手动查看指纹:"
        echo -e "  ${CYAN}find ${HY2_ACME_DIR} -name '*.crt' ! -name '*issuer*'${NC}"
        echo -e "  ${CYAN}openssl x509 -noout -fingerprint -sha256 -in <cert.crt>${NC}"
        echo ""
    fi

    # ── 客户端 YAML 配置 ────────────────────────────────────
    box "客户端配置"
    echo ""

    local yaml_host
    if [[ "$tls_mode" == "1" ]]; then
        yaml_host="$domain"
    else
        yaml_host="${server_ipv4:-${server_ipv6}}"
    fi

    if [[ "$tls_mode" == "2" && -n "$_FP_COLON" ]]; then
        echo -e "${BOLD}# client.yaml（自签名证书）：${NC}"
        echo ""
        echo -e "${BOLD}  ▸ 推荐：禁用验证 + pinSHA256${NC}  ${DIM}（官方文档第三选项卡）${NC}"
        cat <<EOF
${CYAN}server: ${yaml_host}:${port}
auth: ${password}

tls:
  insecure: true
  pinSHA256: ${_FP_COLON}

bandwidth:
  up: 50 mbps
  down: 200 mbps

socks5:
  listen: 127.0.0.1:1080

http:
  listen: 127.0.0.1:8080${NC}
EOF
        echo ""
        echo -e "${BOLD}  ▸ 备选：仅禁用验证${NC}  ${DIM}（有 MITM 中间人攻击风险）${NC}"
        cat <<EOF
${CYAN}tls:
  insecure: true${NC}
EOF
    else
        echo -e "${BOLD}# client.yaml（ACME 受信证书版）：${NC}"
        cat <<EOF
${CYAN}server: ${yaml_host}:${port}
auth: ${password}

bandwidth:
  up: 50 mbps
  down: 200 mbps

socks5:
  listen: 127.0.0.1:1080

http:
  listen: 127.0.0.1:8080${NC}
EOF
    fi

    # ── 导入 URI ────────────────────────────────────────────
    echo ""
    echo -e "${BOLD}# 导入 URI（v2rayN / NekoBox / Shadowrocket 等）：${NC}"
    echo ""

    _url_enc() {
        python3 -c "import urllib.parse,sys; print(urllib.parse.quote(sys.stdin.read().strip()),end='')" \
            <<< "$1" 2>/dev/null \
            || echo "$1" | sed 's/+/%2B/g;s|/|%2F|g;s/=/%3D/g'
    }

    local -a qr_links=()
    _make_uri() {
        local h=$1 lbl=$2
        local addr uri
        [[ "$h" =~ : ]] && addr="[${h}]" || addr="${h}"
        if [[ "$tls_mode" == "2" && -n "$_FP_COLON" ]]; then
            local enc; enc=$(_url_enc "$_FP_B64")
            uri="hysteria2://${password}@${addr}:${port}?insecure=0&sni=${sni}&pinSHA256=${enc}#${lbl}"
        else
            uri="hysteria2://${password}@${addr}:${port}#${lbl}"
        fi
        echo -e "  ${CYAN}${uri}${NC}"
        qr_links+=("$uri")
    }

    if [[ "$tls_mode" == "1" ]]; then
        echo -e "  ${DIM}[域名]${NC}"
        _make_uri "$domain" "HY2-VPS"
    else
        if [[ -n "$server_ipv4" ]]; then
            echo -e "  ${DIM}[IPv4]${NC}"
            _make_uri "$server_ipv4" "HY2-VPS-v4"
        fi
        if [[ -n "$server_ipv6" ]]; then
            echo -e "  ${DIM}[IPv6]${NC}"
            _make_uri "$server_ipv6" "HY2-VPS-v6"
        fi
        [[ -z "$server_ipv4" && -z "$server_ipv6" ]] && warn "未能获取到任何公网 IP，URI 无法生成"
    fi

    # ── 二维码 ──────────────────────────────────────────────
    if (( ${#qr_links[@]} > 0 )); then
        if command -v qrencode &>/dev/null; then
            echo ""
            echo -e "${BOLD}# 二维码：${NC}"
            local i=0
            for link in "${qr_links[@]}"; do
                (( i++ ))
                echo -e "  ${CYAN}${BOLD}(${i})：${NC}"
                qrencode -t ansiutf8 "${link}"
            done
        else
            warn "未安装 qrencode，无法显示二维码（可运行: apt-get install -y qrencode）"
        fi
    fi

    # ── 服务管理命令 ────────────────────────────────────────
    box "服务管理"
    echo ""
    printf "  ${BOLD}%-14s${NC}  ${CYAN}%s${NC}\n" "启动服务"   "systemctl start   hysteria-server"
    printf "  ${BOLD}%-14s${NC}  ${CYAN}%s${NC}\n" "停止服务"   "systemctl stop    hysteria-server"
    printf "  ${BOLD}%-14s${NC}  ${CYAN}%s${NC}\n" "重启服务"   "systemctl restart hysteria-server"
    printf "  ${BOLD}%-14s${NC}  ${CYAN}%s${NC}\n" "查看状态"   "systemctl status  hysteria-server"
    printf "  ${BOLD}%-14s${NC}  ${CYAN}%s${NC}\n" "实时日志"   "journalctl -u hysteria-server -f"
    printf "  ${BOLD}%-14s${NC}  ${CYAN}%s${NC}\n" "编辑配置"   "nano ${HY2_CONF}"
    echo ""
    hr
    if systemctl is-active --quiet hysteria-server 2>/dev/null; then
        echo -e "  服务状态:  ${GREEN}${BOLD}● 运行中 ✅${NC}"
    else
        echo -e "  服务状态:  ${RED}${BOLD}✗ 未运行${NC}"
        warn "服务可能启动失败，查看日志:"
        echo -e "  ${CYAN}journalctl -u hysteria-server --no-pager | tail -20${NC}"
    fi
    hr
    echo ""
}

# ────────────────────────────────────────────────────────────
#  Hysteria 2 主流程入口
# ────────────────────────────────────────────────────────────
install_hysteria2() {
    clear
    box "Hysteria 2 一键安装脚本"
    echo -e "  官方文档: ${CYAN}https://v2.hysteria.network${NC}"
    echo ""

    # ── 已安装检测 ──────────────────────────────────────────
    if hy2_is_installed; then
        echo ""
        warn "检测到系统已安装 Hysteria 2"
        echo ""
        echo "  [1] 卸载后重新安装（推荐）"
        echo "  [2] 仅卸载，不重新安装"
        echo "  [3] 退出，不做任何操作"
        echo ""
        read -rp "请选择 [1/2/3]（默认 1）: " choice
        case "${choice:-1}" in
            1) hy2_do_uninstall ;;
            2) hy2_do_uninstall; echo ""; info "卸载完成。"; exit 0 ;;
            *) info "已取消，退出。"; exit 0 ;;
        esac
    fi

    # ── 收集安装参数 ────────────────────────────────────────
    box "配置参数"
    echo ""

    echo "  TLS 证书模式："
    echo "    [1] ACME 自动申请（Hysteria 2 自动向 CA 申请 + 自动续期）"
    echo "        要求：有效域名已解析到本机 + TCP 80 端口可访问"
    echo "    [2] 自签名证书（无需域名，IP 直连，需配置 SNI + pinSHA256）"
    echo ""
    read -rp "  请选择 [1/2]（默认 2）: " TLS_MODE
    TLS_MODE=${TLS_MODE:-2}

    echo ""
    info "正在检测服务器公网地址..."
    SERVER_IPV4=$(hy2_get_ipv4)
    SERVER_IPV6=$(hy2_get_ipv6)
    [[ -n "$SERVER_IPV4" ]] && info "公网 IPv4 : ${SERVER_IPV4}" || warn "未检测到公网 IPv4"
    [[ -n "$SERVER_IPV6" ]] && info "公网 IPv6 : ${SERVER_IPV6}" || info "未检测到公网 IPv6（单栈服务器）"

    DOMAIN=""; EMAIL=""; ACME_CA="letsencrypt"; SNI=""

    if [[ "$TLS_MODE" == "1" ]]; then
        echo ""
        read -rp "  请输入域名（需已 DNS 解析到本机 IP）: " DOMAIN
        [[ -z "$DOMAIN" ]] && error "域名不能为空"
        read -rp "  请输入邮箱（ACME 通知 + 账号注册）: " EMAIL
        [[ -z "$EMAIL" ]] && error "邮箱不能为空"
        echo ""
        echo "  证书签发机构："
        echo "    [1] Let's Encrypt（默认，推荐）"
        echo "    [2] ZeroSSL"
        read -rp "  请选择 [1/2]（默认 1）: " ca_choice
        [[ "${ca_choice:-1}" == "2" ]] && ACME_CA="zerossl" || ACME_CA="letsencrypt"
    else
        echo ""
        echo "  ${BOLD}SNI 伪装域名设置${NC}"
        echo "  ┌──────────────────────────────────────────────────────"
        echo "  │ 证书 CN/SAN 将使用此域名；客户端 sni 字段须填写相同的值"
        echo "  │ ⚠ 请勿填写 IP 地址，必须是合法域名格式"
        echo "  │ 推荐填写知名网站域名以混淆流量特征"
        echo "  │ 示例: bing.com  /  www.apple.com  /  update.microsoft.com"
        echo "  └──────────────────────────────────────────────────────"
        echo ""
        read -rp "  请输入 SNI 域名（默认: bing.com）: " SNI
        SNI=${SNI:-bing.com}
        SNI=$(echo "$SNI" | sed -E 's|^https?://||;s|/.*||;s/[[:space:]]//g')
        info "SNI 设置为: ${SNI}"
    fi

    echo ""
    read -rp "  监听端口（默认 443）: " PORT
    PORT=${PORT:-443}

    DEFAULT_PASS=$(tr -dc 'A-Za-z0-9!@#^&*' </dev/urandom 2>/dev/null | head -c 20 \
                  || openssl rand -base64 16 | tr -d '=+/')
    read -rp "  认证密码（默认随机: ${DEFAULT_PASS}）: " PASSWORD
    PASSWORD=${PASSWORD:-$DEFAULT_PASS}

    # ── 开始安装 ────────────────────────────────────────────
    hy2_install_deps

    local ARCH VERSION
    ARCH=$(hy2_get_arch)
    VERSION=$(hy2_get_latest_version)
    info "架构: ${ARCH}  |  最新版本: ${VERSION}"

    hy2_download "$VERSION" "$ARCH"
    mkdir -p "${HY2_CONF_DIR}"

    step "写入服务端配置"
    if [[ "$TLS_MODE" == "1" ]]; then
        hy2_write_config_acme "$DOMAIN" "$EMAIL" "$PASSWORD" "$PORT" "$ACME_CA"
        info "配置文件: ${HY2_CONF}"
        info "ACME 证书目录: ${HY2_ACME_DIR}（启动后自动申请）"
    else
        hy2_gen_selfsigned_cert "${SNI}"
        hy2_write_config_selfsigned "$PASSWORD" "$PORT"
        info "配置文件: ${HY2_CONF}"
        info "证书目录: ${HY2_CERT_DIR}"
    fi

    step "启动 Hysteria 2 服务"
    hy2_write_service
    systemctl daemon-reload
    systemctl enable hysteria-server
    systemctl start hysteria-server

    # ── 等待服务完全就绪 ─────────────────────────────────────
    # 自签名模式：等待 systemd 确认服务 active
    # ACME 模式：额外等待证书申请完成，再输出配置信息
    local CERT_FILE=""
    if [[ "$TLS_MODE" == "1" ]]; then
        echo ""
        info "Hysteria 2 正在后台向 ${ACME_CA} 申请证书..."
        info "使用 HTTP challenge，请确保 TCP 80 端口已开放"
        if CERT_FILE=$(hy2_wait_for_acme_cert 2>/dev/null); then
            info "✅ ACME 证书申请完成，继续输出配置信息"
        else
            warn "⚠ 未在限定时间内找到证书文件（申请可能仍在进行中）"
            warn "  可能原因: TCP 80 未开放 / 域名未正确解析 / CA 响应慢"
            warn "  查看日志: journalctl -u hysteria-server -f"
            CERT_FILE=""
        fi
    else
        # 自签名：等待服务 active（最多 10s）
        local waited=0
        while (( waited < 10 )); do
            systemctl is-active --quiet hysteria-server && break
            sleep 1; (( waited++ ))
        done
        if systemctl is-active --quiet hysteria-server; then
            info "systemd 服务已启动"
        else
            warn "服务启动可能失败，请查看日志: journalctl -u hysteria-server -f"
        fi
        CERT_FILE="${HY2_CERT_DIR}/server.crt"
    fi

    # ── 全部就绪后，统一输出配置信息 ────────────────────────
    hy2_print_client_info \
        "$TLS_MODE" "$DOMAIN" "$PASSWORD" "$PORT" "$SNI" \
        "$SERVER_IPV4" "$SERVER_IPV6" "$VERSION" "$CERT_FILE"
}


# ════════════════════════════════════════════════════════════
#  入口
# ════════════════════════════════════════════════════════════
show_main_menu