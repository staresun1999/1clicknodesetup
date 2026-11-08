#!/usr/bin/env bash
# ============================================================
#  代理协议一键安装脚本
#  支持：
#    [1] VLESS + TCP + XTLS-Vision + REALITY（Xray-core）
#    [2] Hysteria 2（ACME 自动证书 / 自签名证书，可指定证书目录）
#    [3] AnyTLS（sing-box 内核；ACME 自动证书 / 自签名证书，可指定证书目录）
#    另含：[4] 查看已有节点配置   [5] 删除已搭建的节点（卸载并清理干净）
#  所有节点搭建完成后，都会输出 Clash / Mihomo 订阅格式配置（单节点），
#  并保存到 /root/clash_*.yaml
#  支持系统：Ubuntu 20.04/22.04/24.04 | Debian 10/11/12 | Alpine 3.x
#            CentOS / Rocky / AlmaLinux（仅 Hysteria 2 / AnyTLS）
#  服务管理：systemd 或 OpenRC（自动检测）
# ============================================================

# Alpine 默认没有 bash：若被 sh 调用，先安装 bash 再用 bash 重新执行
if [ -z "${BASH_VERSION:-}" ]; then
    if command -v apk >/dev/null 2>&1; then
        apk add --no-cache -q bash >/dev/null 2>&1 || true
    fi
    exec bash "$0" "$@"
fi

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

# ════════════════════════════════════════════════════════════
#  系统检测（发行版族 + 服务管理器 systemd / OpenRC）
# ════════════════════════════════════════════════════════════
OS_ID=""; OS_VER=""; OS_FAMILY=""; INIT_SYS=""

detect_system() {
    [[ -f /etc/os-release ]] || error "无法检测操作系统（缺少 /etc/os-release）"
    # shellcheck disable=SC1091
    . /etc/os-release
    OS_ID="${ID:-unknown}"
    OS_VER="${VERSION_ID:-}"
    case "$OS_ID" in
        ubuntu|debian)                          OS_FAMILY=debian ;;
        alpine)                                 OS_FAMILY=alpine ;;
        centos|rhel|rocky|almalinux|fedora|ol)  OS_FAMILY=rhel ;;
        *) error "不支持的系统：${OS_ID}" ;;
    esac

    if [[ -d /run/systemd/system ]] && command -v systemctl &>/dev/null; then
        INIT_SYS=systemd
    elif command -v rc-service &>/dev/null; then
        INIT_SYS=openrc
    else
        error "未检测到 systemd 或 OpenRC，无法管理服务"
    fi
    info "系统: ${OS_ID} ${OS_VER}  |  发行族: ${OS_FAMILY}  |  服务管理: ${INIT_SYS}"
}

# ════════════════════════════════════════════════════════════
#  包管理抽象（apt / apk / dnf|yum）
# ════════════════════════════════════════════════════════════
pkg_update() {
    case "$OS_FAMILY" in
        debian) apt-get update -qq ;;
        alpine) apk update -q ;;
        *)      return 0 ;;
    esac
}

pkg_install() {
    case "$OS_FAMILY" in
        debian) DEBIAN_FRONTEND=noninteractive apt-get install -y -qq "$@" ;;
        alpine) apk add --no-cache -q "$@" ;;
        rhel)
            if command -v dnf &>/dev/null; then dnf install -y -q "$@"
            else yum install -y -q "$@"; fi ;;
    esac
}

pkg_clean() {
    case "$OS_FAMILY" in
        debian) apt-get clean >/dev/null 2>&1 || true
                dpkg --configure -a >/dev/null 2>&1 || true ;;
        alpine) rm -rf /var/cache/apk/* ;;
        *) : ;;
    esac
}

# Alpine 基础工具：coreutils 提供 readlink -m / sleep 小数等，findutils 提供 find -quit，
# procps 提供 free / pkill，iproute2 提供 ip 命令（公网 IP 回退探测用）
ensure_base_tools() {
    [[ "$OS_FAMILY" == alpine ]] || return 0
    info "检查 Alpine 基础工具（curl jq openssl tar coreutils findutils procps iproute2）..."
    apk add --no-cache -q bash curl jq openssl tar ca-certificates \
        coreutils findutils procps iproute2 \
        || warn "基础工具安装失败，后续步骤可能异常"
}

# 没有 clear 命令时的兜底（部分最小化 Alpine 没有 ncurses）
command -v clear &>/dev/null || clear() { printf '\033[H\033[2J'; }

# ════════════════════════════════════════════════════════════
#  服务管理兼容层：同名函数覆盖 systemctl / journalctl
#  systemd 下直接透传；OpenRC 下翻译为 rc-service / rc-update
# ════════════════════════════════════════════════════════════
systemctl() {
    if [[ "$INIT_SYS" == systemd ]]; then command systemctl "$@"; return; fi

    local action="${1:-}" a name="" now=0
    shift || true
    for a in "$@"; do
        case "$a" in
            --now) now=1 ;;
            --*)   ;;
            *)     name="${a%.service}" ;;
        esac
    done

    case "$action" in
        daemon-reload|reset-failed) return 0 ;;
        start|stop|restart|status)  rc-service "$name" "$action" ;;
        enable)
            rc-update add "$name" default >/dev/null 2>&1 || true
            if (( now )); then rc-service "$name" start; fi ;;
        disable)
            if (( now )); then rc-service "$name" stop >/dev/null 2>&1 || true; fi
            rc-update del "$name" default >/dev/null 2>&1 || true ;;
        is-active)  rc-service "$name" status >/dev/null 2>&1 ;;
        is-enabled)
            rc-update show default 2>/dev/null \
                | awk -F'|' -v n="$name" '{ gsub(/[ \t]/, "", $1); if ($1 == n) f = 1 } END { exit !f }' ;;
        list-unit-files) [[ -e "/etc/init.d/${name}" ]] ;;
        *) warn "OpenRC 下未实现的 systemctl 操作：${action}"; return 1 ;;
    esac
}

# journalctl -u NAME [-n N] [-f]：OpenRC 下读取 /var/log/NAME.log
journalctl() {
    if [[ "$INIT_SYS" == systemd ]]; then command journalctl "$@"; return; fi

    local a prev="" unit="" lines=50 follow=0
    for a in "$@"; do
        case "$prev" in
            -u) unit="${a%.service}" ;;
            -n) lines="$a" ;;
        esac
        if [[ "$a" == -f ]]; then follow=1; fi
        prev="$a"
    done
    local lf="/var/log/${unit}.log"
    if [[ -z "$unit" || ! -f "$lf" ]]; then
        warn "未找到服务日志：${lf}"
        return 1
    fi
    if (( follow )); then tail -n "$lines" -f "$lf"; else tail -n "$lines" "$lf"; fi
}

# 服务单元路径
svc_unit_path() {
    local n=${1%.service}
    if [[ "$INIT_SYS" == systemd ]]; then
        echo "/etc/systemd/system/${n}.service"
    else
        echo "/etc/init.d/${n}"
    fi
}

# 删除服务单元（含开机自启记录与日志）
svc_remove_unit() {
    local n=${1%.service}
    if [[ "$INIT_SYS" == openrc ]]; then
        rc-update del "$n" default >/dev/null 2>&1 || true
        rm -f "/var/log/${n}.log"
    fi
    rm -f "$(svc_unit_path "$n")" "/etc/systemd/system/multi-user.target.wants/${n}.service"
}

# 生成服务单元
#   参数: 服务名 描述 工作目录 可执行文件 启动参数
svc_write_unit() {
    local name=${1%.service} desc=$2 wdir=$3 bin=$4 args=$5 path
    path=$(svc_unit_path "$name")
    mkdir -p "$(dirname "$path")"

    if [[ "$INIT_SYS" == systemd ]]; then
        cat > "$path" <<EOF
[Unit]
Description=${desc}
After=network.target nss-lookup.target

[Service]
Type=simple
User=root
WorkingDirectory=${wdir}
ExecStart=${bin} ${args}
Restart=on-failure
RestartSec=5s
LimitNOFILE=1048576

[Install]
WantedBy=multi-user.target
EOF
    else
        cat > "$path" <<EOF
#!/sbin/openrc-run
# 由 proxy 安装脚本生成（OpenRC / supervise-daemon）
name="${name}"
description="${desc}"
command="${bin}"
command_args="${args}"
directory="${wdir}"
pidfile="/run/${name}.pid"
supervisor="supervise-daemon"
respawn_delay=5
respawn_max=0
rc_ulimit="-n 1048576"
output_log="/var/log/${name}.log"
error_log="/var/log/${name}.log"

depend() {
    need net
    after firewall
}
EOF
        chmod 755 "$path"
    fi
}

# 启动时检测系统
detect_system

# ════════════════════════════════════════════════════════════
#  变量 / 通用辅助
# ════════════════════════════════════════════════════════════

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
#  通用：证书目录（Hysteria 2 / AnyTLS 共用）
#  - 路径必须是绝对路径，且只允许 字母 数字 . _ - / @ +
#  - 拒绝直接使用 /etc /usr /root 等系统目录
#  - 卸载时只删除脚本生成的证书文件，绝不 rm -rf 用户指定的目录
# ════════════════════════════════════════════════════════════
CERT_DIR_RESULT=""

cert_dir_normalize() {
    local d=$1 re='^/[A-Za-z0-9._/@+-]+$'
    if [[ "$d" != /* ]]; then
        warn "请填写绝对路径（以 / 开头）"
        return 1
    fi
    if ! [[ "$d" =~ $re ]]; then
        warn "路径只能包含字母、数字和 . _ - / @ +（不能有空格、引号等特殊字符）"
        return 1
    fi
    d=$(readlink -m -- "$d" 2>/dev/null || echo "$d")
    case "$d" in
        /|/bin|/boot|/dev|/etc|/lib|/lib64|/proc|/run|/sbin|/sys|/usr|/var|/root|/home|/tmp|/mnt|/opt|/srv)
            warn "不能直接使用系统目录 ${d}，请指定一个专用子目录（例如 ${d%/}/proxy-certs）"
            return 1 ;;
    esac
    if [[ -e "$d" && ! -d "$d" ]]; then
        warn "${d} 已存在且不是目录"
        return 1
    fi
    CERT_DIR_RESULT="$d"
    return 0
}

# 交互询问证书目录；结果写入全局 CERT_DIR_RESULT
ask_cert_dir() {
    local label=$1 def=$2 v
    while true; do
        read -rp "  ${label}（默认 ${def}）: " v
        v=${v:-$def}
        if cert_dir_normalize "$v"; then
            break
        fi
    done
    info "${label}: ${CERT_DIR_RESULT}"
    return 0
}

# 创建证书目录（已存在则原样使用，不改权限）
cert_dir_prepare() {
    local d=$1
    if [[ ! -d "$d" ]]; then
        mkdir -p "$d" || error "无法创建证书目录: ${d}"
        chmod 700 "$d"
    fi
    [[ -w "$d" ]] || error "证书目录不可写: ${d}"
    return 0
}

# 清理证书目录：只删除指定的文件/子目录名；目录变空后才 rmdir
#   用法: cert_dir_cleanup <目录> <名称1> [名称2 ...]
cert_dir_cleanup() {
    local d=$1 f
    shift
    [[ -d "$d" ]] || return 0
    for f in "$@"; do
        if [[ -e "$d/$f" || -L "$d/$f" ]]; then
            info "删除 ${d}/${f}"
            rm -rf -- "${d:?}/${f:?}"
        fi
    done
    if rmdir "$d" 2>/dev/null; then
        info "已删除空目录 ${d}"
    fi
    return 0
}

# ════════════════════════════════════════════════════════════
#  通用：Clash / Mihomo 订阅格式配置（单节点）
#  依赖 Part 3 里的 at_yaml_str / at_yaml_host（运行时才调用，顺序无关）
# ════════════════════════════════════════════════════════════
RE_CLASH_FILE="/root/clash_reality.yaml"
HY2_CLASH_FILE="/root/clash_hysteria2.yaml"
AT_CLASH_FILE="/root/clash_anytls.yaml"

# VLESS + REALITY 节点（Mihomo 格式）
#   参数: 名称 服务器 端口 UUID SNI 公钥 ShortId
clash_node_reality() {
    local name=$1 host=$2 port=$3 uuid=$4 sni=$5 pbk=$6 sid=$7
    echo "  - name: $(at_yaml_str "$name")"
    echo "    type: vless"
    echo "    server: $(at_yaml_host "$host")"
    echo "    port: ${port}"
    echo "    uuid: ${uuid}"
    echo "    network: tcp"
    echo "    udp: true"
    echo "    tls: true"
    echo "    flow: xtls-rprx-vision"
    echo "    servername: ${sni}"
    echo "    client-fingerprint: chrome"
    echo "    reality-opts:"
    echo "      public-key: \"${pbk}\""
    echo "      short-id: \"${sid}\""
    return 0
}

# Hysteria 2 节点（Mihomo 格式）
#   参数: 名称 服务器 端口 密码 SNI 证书指纹(可空) 客户端上传Mbps 客户端下载Mbps 是否跳过校验(0/1)
#   有指纹 → 固定证书指纹；无指纹且 insecure=1 → 跳过校验；否则走系统信任链（ACME）
clash_node_hy2() {
    local name=$1 host=$2 port=$3 password=$4 sni=$5 fp=${6:-} ul=${7:-0} dl=${8:-0} insecure=${9:-0}
    echo "  - name: $(at_yaml_str "$name")"
    echo "    type: hysteria2"
    echo "    server: $(at_yaml_host "$host")"
    echo "    port: ${port}"
    echo "    password: $(at_yaml_str "$password")"
    echo "    sni: ${sni}"
    if [[ -n "$fp" ]]; then
        echo "    skip-cert-verify: false"
        echo "    fingerprint: ${fp}"
    elif [[ "$insecure" == "1" ]]; then
        echo "    skip-cert-verify: true"
    else
        echo "    skip-cert-verify: false"
    fi
    if (( ul > 0 )); then
        echo "    up: \"${ul} Mbps\""
    fi
    if (( dl > 0 )); then
        echo "    down: \"${dl} Mbps\""
    fi
    return 0
}

# AnyTLS 节点（Mihomo 格式）
#   参数: 名称 服务器 端口 密码 SNI TLS模式(1=ACME 2=自签名) 证书指纹(可空)
clash_node_anytls() {
    local name=$1 host=$2 port=$3 password=$4 sni=$5 tls_mode=$6 fp=${7:-}
    echo "  - name: $(at_yaml_str "$name")"
    echo "    type: anytls"
    echo "    server: $(at_yaml_host "$host")"
    echo "    port: ${port}"
    echo "    password: $(at_yaml_str "$password")"
    echo "    udp: true"
    echo "    sni: ${sni}"
    if [[ "$tls_mode" == "2" && -n "$fp" ]]; then
        echo "    fingerprint: ${fp}"
        echo "    skip-cert-verify: false"
    elif [[ "$tls_mode" == "2" ]]; then
        echo "    skip-cert-verify: true"
    else
        echo "    skip-cert-verify: false"
    fi
    return 0
}

# 把单个节点包装成完整的 Clash / Mihomo 配置（订阅文件内容）
#   参数: 节点名称 节点YAML（缩进已处理好的 "  - name: ..." 块）
clash_full_config() {
    local name=$1 node=$2 n
    n=$(at_yaml_str "$name")
    cat <<EOF
mixed-port: 7890
allow-lan: false
mode: rule
log-level: info
ipv6: true

dns:
  enable: true
  ipv6: true
  enhanced-mode: fake-ip
  default-nameserver:
    - 223.5.5.5
    - 119.29.29.29
  nameserver:
    - https://dns.alidns.com/dns-query
    - https://doh.pub/dns-query

proxies:
${node}

proxy-groups:
  - name: PROXY
    type: select
    proxies:
      - ${n}
      - DIRECT

rules:
  - GEOIP,LAN,DIRECT,no-resolve
  - GEOIP,CN,DIRECT
  - MATCH,PROXY
EOF
}

# 输出到终端并保存为文件
#   参数: 节点名称 保存路径 节点YAML
clash_emit() {
    local name=$1 file=$2 node=$3 cfg
    cfg=$(clash_full_config "$name" "$node")
    printf '%s\n' "$cfg" > "$file"
    chmod 600 "$file"
    echo ""
    echo -e "${BOLD}# Clash / Mihomo 订阅格式配置（单节点）：${NC}"
    echo -e "  ${DIM}整段保存为 .yaml 即可作为配置/订阅文件导入；已有配置只需复制 proxies: 下的节点${NC}"
    echo ""
    printf '%b%s%b\n' "$CYAN" "$cfg" "$NC"
    echo ""
    info "Clash 配置已保存至 ${file}"
    return 0
}

# ════════════════════════════════════════════════════════════
#  必须 root
# ════════════════════════════════════════════════════════════
[[ $EUID -ne 0 ]] && error "请使用 root 用户运行此脚本，或使用 sudo bash $0"
ensure_base_tools
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
    echo "         (Xray-core，抗检测，推荐；REALITY 借用目标站证书，无需本地证书)"
    echo ""
    echo "    [2]  Hysteria 2"
    echo "         (基于 QUIC，高速，支持 ACME 证书 / 自签名，可指定证书目录)"
    echo ""
    echo "    [3]  AnyTLS"
    echo "         (sing-box 内核，TLS + 流量填充，支持 ACME 证书 / 自签名，可指定证书目录)"
    echo ""
    echo "    [4]  查看当前已有节点配置"
    echo ""
    echo "    [5]  删除已搭建的节点"
    echo "         (卸载服务，清理程序 / 配置 / 证书 / 日志，删干净)"
    echo ""
    echo "    [6]  多节点管理（同协议多节点 / 暂停·恢复·删除单个节点）"
    echo ""
    echo "    [7]  启用 / 停用协议"
    echo "         (停止服务并取消开机自启，配置保留；随时可重新启用)"
    echo ""
    echo "    [8]  WARP 出口（一键套 WARP）"
    echo "         (让 REALITY / Hysteria 2 / AnyTLS 的出口 IP 变成 Cloudflare WARP)"
    echo ""
    echo "    [0]  退出"
    echo ""
    read -rp "  请输入 [0-8]（默认 1）: " PROTO_CHOICE
    PROTO_CHOICE=${PROTO_CHOICE:-1}
    case "$PROTO_CHOICE" in
        1) install_reality; return ;;
        2) install_hysteria2; return ;;
        3) install_anytls; return ;;
        4) show_existing_configs ;;
        5) delete_nodes ;;
        6) node_manage_menu ;;
        7) toggle_protocols ;;
        8) warp_menu ;;
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

        # ── Clash / Mihomo 订阅格式（单节点）──────────────────
        local clash_host="${server_ipv4:-$server_ipv6}"
        clash_emit "REALITY-${clash_host}" "$RE_CLASH_FILE" \
            "$(clash_node_reality "REALITY-${clash_host}" "$clash_host" "$port" "$uuid" "$sni" "$public_key" "$short_id")"
    else
        warn "未能生成完整分享链接，请查看 ${info_file} 或手动填写服务器公网 IP"
    fi
}

show_hy2_existing_config() {
    local config="${HY2_CONF:-/etc/hysteria/config.yaml}"
    [[ -f "$config" ]] || return 1

    # 证书目录可能是安装时自定义的，先从配置里读回来
    hy2_load_paths_from_conf

    box "当前 Hysteria 2 节点"
    echo -e "  ${BOLD}配置文件${NC}: ${CYAN}${config}${NC}"

    local port="" password="" domain="" email="" ca=""
    local tls_mode="" server_ipv4="" server_ipv6=""
    local cert_file="" sni="" status cert_dir=""
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
        cert_dir="${HY2_ACME_DIR:-/etc/hysteria/acme}"
        cert_file=$(find "$cert_dir" -type f -name '*.crt' ! -name '*issuer*' -print -quit 2>/dev/null || true)
    else
        tls_mode="自签名"
        cert_dir="${HY2_CERT_DIR:-/etc/hysteria/certs}"
        cert_file="${cert_dir}/server.crt"
    fi

    if [[ -n "$cert_file" && -f "$cert_file" ]]; then
        sni=$(openssl x509 -in "$cert_file" -noout -subject -nameopt RFC2253 2>/dev/null \
            | sed -nE 's/^subject=.*CN=([^,]+).*$/\1/p')
    fi

    if systemctl is-active --quiet "${HY2_SVC_NAME:-hysteria-server}" 2>/dev/null; then
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
    printf "  ${BOLD}证书目录${NC}:   %s\n" "$cert_dir"
    [[ -n "$cert_file" ]] && printf "  ${BOLD}证书${NC}:       %s\n" "$cert_file"

    local bw_up bw_down
    bw_up=$(awk '/^bandwidth:/{f=1;next} f&&/^[^[:space:]]/{exit} f&&/^[[:space:]]+up:/{print $2" "$3; exit}' "$config" 2>/dev/null || true)
    bw_down=$(awk '/^bandwidth:/{f=1;next} f&&/^[^[:space:]]/{exit} f&&/^[[:space:]]+down:/{print $2" "$3; exit}' "$config" 2>/dev/null || true)
    if [[ -n "$bw_up" || -n "$bw_down" ]]; then
        printf "  ${BOLD}带宽限制${NC}:   服务端 up %s / down %s\n" "${bw_up:-不限}" "${bw_down:-不限}"
        printf "              ${DIM}（方向相反：服务端 up = 客户端下载，服务端 down = 客户端上传）${NC}\n"
    fi
    if grep -qE '^[[:space:]]*disablePathMTUDiscovery:[[:space:]]*true' "$config"; then
        printf "  ${BOLD}MTU 探测${NC}:   已关闭\n"
    fi

    # 服务端 up/down 与客户端相反：转换成「客户端上传 / 下载」供 Clash 配置使用
    HY2_UL_MBPS=0
    HY2_DL_MBPS=0
    if [[ "$bw_up" =~ ^([0-9]+)[[:space:]]+[Mm]bps ]]; then
        HY2_DL_MBPS=$(( 10#${BASH_REMATCH[1]} ))
    fi
    if [[ "$bw_down" =~ ^([0-9]+)[[:space:]]+[Mm]bps ]]; then
        HY2_UL_MBPS=$(( 10#${BASH_REMATCH[1]} ))
    fi

    server_ipv4=$(hy2_get_ipv4 2>/dev/null || true)
    server_ipv6=$(hy2_get_ipv6 2>/dev/null || true)
    echo ""
    _FP_B64=""
    _FP_COLON=""
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
                (( ++i ))
                echo -e "  ${CYAN}${BOLD}二维码 (${i})：${NC}"
                qrencode -t ansiutf8 "${link}"
            done
        else
            warn "未安装 qrencode，无法显示二维码（可运行: apt-get install -y qrencode）"
        fi
    fi

    # ── Clash / Mihomo 订阅格式（单节点）──────────────────────
    local c_host="" c_sni="" c_fp="" c_insecure=0
    if [[ "$tls_mode" == "ACME" ]]; then
        c_host="$domain"
        c_sni="$domain"
    else
        c_host="${server_ipv4:-$server_ipv6}"
        c_sni="$sni"
        c_fp="${_FP_COLON:-}"
        if [[ -z "$c_fp" ]]; then
            c_insecure=1
        fi
    fi
    if [[ -n "$c_host" && -n "$c_sni" && -n "$password" && -n "$port" ]]; then
        clash_emit "Hysteria2-${c_host}${HY2_NODE_TAG:-}" "$HY2_CLASH_FILE" \
            "$(clash_node_hy2 "Hysteria2-${c_host}${HY2_NODE_TAG:-}" "$c_host" "$port" "$password" "$c_sni" "$c_fp" "$HY2_UL_MBPS" "$HY2_DL_MBPS" "$c_insecure")"
    else
        warn "未能从配置中提取完整信息，无法生成 Clash 配置"
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
    if show_anytls_existing_config; then
        found=1
    fi
    if (( found == 1 )); then
        show_extra_nodes_all || true
    fi
    if (( found == 0 )); then
        warn "未找到本脚本创建的 Xray、Hysteria 2 或 AnyTLS 配置"
        echo ""
        echo "  Xray 配置: /usr/local/etc/xray/config.json"
        echo "  Hysteria 2 配置: /etc/hysteria/config.yaml"
        echo "  AnyTLS 配置: /etc/anytls-box/config.json"
    fi

    echo ""
    read -rp "按回车返回主菜单..." _
}


# ╔══════════════════════════════════════════════════════════╗
# ║         PART 1 — VLESS + XTLS-Vision + REALITY          ║
# ╚══════════════════════════════════════════════════════════╝

# ────────────────────────────────────────────────────────────
#  检测系统（REALITY 支持 Ubuntu / Debian / Alpine）
# ────────────────────────────────────────────────────────────
re_detect_os() {
    case "$OS_FAMILY" in
        debian|alpine) info "检测到系统：${OS_ID} ${OS_VER}（服务管理：${INIT_SYS}）" ;;
        *) error "REALITY 脚本仅支持 Ubuntu / Debian / Alpine，当前系统：${OS_ID}" ;;
    esac
}

# ────────────────────────────────────────────────────────────
#  安装依赖（REALITY）
#  注意：第三方 apt 源（如已失效的 Caddy 源）导致更新返回非零时，
#  不应中断安装，继续使用现有缓存即可。
# ────────────────────────────────────────────────────────────
re_install_deps() {
    step "安装依赖"

    local i ok=0
    for i in 1 2; do
        if pkg_update; then ok=1; break; fi
        warn "软件源更新返回错误（可能是某个第三方源失效），重试 (${i}/2)..."
        sleep 2
    done
    (( ok == 0 )) && warn "软件源更新存在失败，已忽略，继续使用现有缓存安装依赖"

    local -a pkgs
    if [[ "$OS_FAMILY" == alpine ]]; then
        pkgs=(bash curl wget unzip jq qrencode openssl ca-certificates coreutils)
    else
        pkgs=(curl wget unzip jq qrencode openssl)
    fi
    pkg_install "${pkgs[@]}" 2>/dev/null \
        || pkg_install curl unzip jq openssl \
        || error "依赖安装失败。若是 apt 源问题，可临时禁用出错的源后重试；Alpine 请检查 /etc/apk/repositories"

    local c
    for c in curl unzip jq openssl; do
        command -v "$c" &>/dev/null || error "缺少依赖命令: ${c}"
    done
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
    svc_write_unit xray "Xray Service" "/usr/local/etc/xray" "$XRAY_BIN" \
        "run -config /usr/local/etc/xray/config.json"

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

    echo -e "${YELLOW}提示：REALITY 不使用本地证书（握手时借用 target 站点的真实证书），因此这里没有「证书目录」可指定；${NC}"
    echo -e "${YELLOW}      如需指定证书目录，请使用 Hysteria 2 / AnyTLS。${NC}"
    echo ""

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
        warn "未检测到防火墙，请手动放行端口 ${RE_PORT}（Alpine 可执行 apk add iptables 后重试）"
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

    # ── Clash / Mihomo 订阅格式（单节点，优先 IPv4）────────────
    local clash_host="${server_ipv4:-$server_ipv6}"
    clash_emit "REALITY-${clash_host}" "$RE_CLASH_FILE" \
        "$(clash_node_reality "REALITY-${clash_host}" "$clash_host" "$RE_PORT" "$RE_UUID" "$RE_SERVER_NAME" "$RE_PUBLIC_KEY" "$RE_SHORT_ID")"

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

Clash / Mihomo 订阅配置（单节点）：
  ${RE_CLASH_FILE}

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

    if [[ -x "$RE_XRAY_BIN" && -f "$RE_XRAY_CONF" ]]; then
        warn "检测到系统已安装 REALITY（Xray）"
        echo ""
        echo "  [1] 覆盖重装（会清除该协议的全部节点）"
        echo "  [2] 新增一个节点（保留现有节点）"
        echo "  [3] 退出，不做任何操作"
        echo ""
        local re_choice
        read -rp "请选择 [1/2/3]（默认 3）: " re_choice
        case "${re_choice:-3}" in
            1) rm -f /root/clash_reality_*.yaml "${PAUSED_DIR}"/re-*.json ;;
            2) re_add_node || true; return 0 ;;
            *) info "已取消，退出。"; exit 0 ;;
        esac
    fi

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
HY2_SERVICE="$(svc_unit_path hysteria-server)"
HY2_SVC_NAME="hysteria-server"      # 额外节点会在函数内临时覆盖
HY2_NODE_TAG=""                     # Clash 节点名后缀（额外节点用）

# 证书目录：默认值固定不变；实际使用的 HY2_CERT_DIR / HY2_ACME_DIR
# 会在安装时由用户指定，或在查看 / 卸载时从 config.yaml 读回
HY2_CERT_DIR_DEFAULT="${HY2_CONF_DIR}/certs"
HY2_ACME_DIR_DEFAULT="${HY2_CONF_DIR}/acme"
HY2_CERT_DIR="$HY2_CERT_DIR_DEFAULT"     # 自签名证书目录（server.crt / server.key）
HY2_ACME_DIR="$HY2_ACME_DIR_DEFAULT"     # ACME 数据目录（证书 / 账号 / 锁）

# 全局：证书指纹（供 URI 使用）
_FP_B64=""
_FP_COLON=""

# 全局：ACME 等待结果（避免命令替换吞掉输出）
HY2_CERT_FOUND=""

# 全局：带宽限制（按「客户端实际速度」记录，单位 Mbps，0 = 不限速）与 MTU 探测开关
HY2_UL_MBPS=50     # 客户端上传
HY2_DL_MBPS=200    # 客户端下载
HY2_NO_PMTUD=0     # 1 = 关闭 QUIC 路径 MTU 探测

# ────────────────────────────────────────────────────────────
#  检测是否已安装
# ────────────────────────────────────────────────────────────
hy2_is_installed() {
    [[ -f "$HY2_BIN" ]] || systemctl list-unit-files hysteria-server.service &>/dev/null 2>&1
}

# ────────────────────────────────────────────────────────────
#  从已有 config.yaml 读回证书目录（安装时可能指定了自定义目录）
#    ACME 模式  → acme.dir          → HY2_ACME_DIR
#    自签名模式 → tls.cert 所在目录 → HY2_CERT_DIR
# ────────────────────────────────────────────────────────────
hy2_load_paths_from_conf() {
    [[ -f "$HY2_CONF" ]] || return 0
    local v=""
    if grep -q '^acme:' "$HY2_CONF"; then
        v=$(sed -nE 's/^[[:space:]]*dir:[[:space:]]*(.*[^[:space:]])[[:space:]]*$/\1/p' "$HY2_CONF" | head -1 || true)
        if [[ -n "$v" ]]; then
            HY2_ACME_DIR="$v"
        fi
    else
        v=$(sed -nE 's/^[[:space:]]*cert:[[:space:]]*(.*[^[:space:]])[[:space:]]*$/\1/p' "$HY2_CONF" | head -1 || true)
        if [[ -n "$v" ]]; then
            HY2_CERT_DIR="$(dirname "$v")"
        fi
    fi
    return 0
}

# ────────────────────────────────────────────────────────────
#  卸载 & 清理
# ────────────────────────────────────────────────────────────
hy2_do_uninstall() {
    step "卸载现有 Hysteria 2 并清理所有文件"
    hy2_purge_extras

    # 必须先于删除配置之前读回证书目录
    hy2_load_paths_from_conf

    systemctl stop    hysteria-server 2>/dev/null || true
    systemctl disable hysteria-server 2>/dev/null || true
    systemctl daemon-reload           2>/dev/null || true

    local t
    local targets=(
        "$HY2_BIN"
        "$HY2_SERVICE"
        "$HY2_CONF_DIR"
        "/var/log/hysteria"
        "$HY2_CLASH_FILE"
    )
    for t in "${targets[@]}"; do
        [[ -e "$t" ]] && { info "删除 $t"; rm -rf "$t"; }
    done

    # 自定义证书目录（不在 /etc/hysteria 之内）：只删除脚本生成的内容，不 rm -rf 整个目录
    if [[ "$HY2_CERT_DIR" != "${HY2_CONF_DIR}"/* ]]; then
        cert_dir_cleanup "$HY2_CERT_DIR" server.crt server.key
    fi
    if [[ "$HY2_ACME_DIR" != "${HY2_CONF_DIR}"/* ]]; then
        cert_dir_cleanup "$HY2_ACME_DIR" acme certificates locks ocsp
    fi

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
    ip=$(ip -4 addr show scope global 2>/dev/null \
            | awk '/inet /{ sub(/\/.*/, "", $2); print $2; exit }') || true
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
#  amd64-avx 版按 x86-64-v3 微架构编译，需要 AVX / AVX2 / BMI1 / BMI2 / FMA / MOVBE 全部支持，
#  只检测 avx 不足以保证能运行，因此逐项校验，任一缺失则使用通用 amd64 版
# ────────────────────────────────────────────────────────────
hy2_get_arch() {
    local m; m=$(uname -m)
    case "$m" in
        x86_64)
            local flags f
            flags=$(grep -m1 '^flags' /proc/cpuinfo 2>/dev/null || true)
            for f in avx avx2 bmi1 bmi2 fma movbe; do
                if ! grep -qw "$f" <<< "$flags"; then
                    echo "amd64"
                    return 0
                fi
            done
            echo "amd64-avx" ;;
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
#  低内存环境（如 96M 的 LXC 容器）辅助函数
#  在 LXC 中 swapon 常因宿主机限制而失败（Operation not permitted），
#  这里静默尝试，失败就跳过，不影响主流程。
# ────────────────────────────────────────────────────────────
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

# 单个包安装（函数名保留以兼容旧调用；按发行版自动选择 apt / apk / dnf）
hy2_apt_install_one() {
    local pkg="$1" required="${2:-1}" i
    command -v "$pkg" &>/dev/null && return 0

    for i in 1 2; do
        if pkg_install "$pkg"; then return 0; fi
        warn "安装 ${pkg} 失败（可能是内存不足被系统杀死），清理缓存后重试 (${i}/2)..."
        pkg_clean
        sleep 2
    done

    if [[ "$required" == "1" ]]; then
        return 1
    fi
    warn "${pkg} 安装失败，已跳过（非必需，脚本继续）"
    return 0
}

hy2_install_deps() {
    step "安装依赖（curl openssl xxd）"

    if [[ "$OS_FAMILY" == debian || "$OS_FAMILY" == alpine ]]; then
        hy2_try_swap

        local i ok=0
        for i in 1 2 3; do
            if pkg_update; then ok=1; break; fi
            warn "软件源更新失败，重试 (${i}/3)..."
            sleep 2
        done
        (( ok == 0 )) && warn "软件源更新多次失败，尝试使用现有缓存继续安装"

        local fail=0
        hy2_apt_install_one curl    1 || fail=1
        hy2_apt_install_one openssl 1 || fail=1
        # xxd 体积较大且非核心功能，装不上时降级为非必需（有 python3 回退）
        hy2_apt_install_one xxd     0 || true

        hy2_cleanup_swap

        if (( fail == 1 )); then
            error "依赖安装失败，请手动安装 curl 与 openssl 后重试（Alpine: apk add curl openssl）"
        fi
        if command -v xxd &>/dev/null; then
            info "依赖已就绪：curl / openssl / xxd"
        else
            warn "依赖已就绪：curl / openssl（xxd 缺失，将使用 python3 回退）"
        fi
    else
        pkg_install curl openssl vim-common 2>/dev/null || pkg_install curl openssl
    fi
}

# ────────────────────────────────────────────────────────────
#  下载 Hysteria 2 二进制
#  以「能否实际运行」为准：标志检测通过也可能运行失败（如虚拟化环境屏蔽指令），
#  失败则回退到通用 amd64 版本
# ────────────────────────────────────────────────────────────
# 仅负责下载到 HY2_BIN，不做运行检测
_hy2_fetch() {
    local version=$1 arch=$2
    local url="https://github.com/apernet/hysteria/releases/download/${version}/hysteria-linux-${arch}"
    info "URL: ${url}"
    curl -fL --progress-bar -o "$HY2_BIN" "$url" || return 1
    chmod +x "$HY2_BIN"
}

hy2_download() {
    local version=$1 arch=$2
    step "下载 Hysteria 2 ${version} (${arch})"
    _hy2_fetch "$version" "$arch" \
        || error "下载失败，请检查网络连接"

    if ! "$HY2_BIN" version &>/dev/null && [[ "$arch" != "amd64" ]]; then
        warn "${arch} 版本无法在此 CPU 上运行，回退到通用 amd64 版本"
        _hy2_fetch "$version" amd64 || error "通用版本下载失败"
    fi

    "$HY2_BIN" version &>/dev/null \
        || error "Hysteria 无法在此机器上运行，请确认 CPU 架构（x86_64 / arm64）"
    info "✅ 二进制已安装至 ${HY2_BIN}"
}

# ────────────────────────────────────────────────────────────
#  询问证书目录
#    自签名：证书 / 私钥（server.crt / server.key）生成到该目录
#    ACME  ：Hysteria 2 把申请到的证书、账号信息存放在该目录（续期也用它）
#  结果写入全局 HY2_CERT_DIR / HY2_ACME_DIR
# ────────────────────────────────────────────────────────────
hy2_ask_cert_dir() {
    local mode=$1
    echo ""
    if [[ "$mode" == "1" ]]; then
        echo -e "  ${BOLD}ACME 证书目录${NC}"
        echo "  Hysteria 2 申请到的证书、ACME 账号信息都保存在这里，到期续签也使用该目录。"
        ask_cert_dir "ACME 证书目录" "$HY2_ACME_DIR_DEFAULT"
        HY2_ACME_DIR="$CERT_DIR_RESULT"
    else
        echo -e "  ${BOLD}自签名证书目录${NC}"
        echo "  生成的证书 server.crt 与私钥 server.key 将放在这里。"
        ask_cert_dir "自签名证书目录" "$HY2_CERT_DIR_DEFAULT"
        HY2_CERT_DIR="$CERT_DIR_RESULT"
    fi
    return 0
}

# ────────────────────────────────────────────────────────────
#  生成自签名 TLS 证书（输出到 HY2_CERT_DIR）
# ────────────────────────────────────────────────────────────
hy2_gen_selfsigned_cert() {
    local sni=$1
    step "生成自签名 TLS 证书（P-256，有效期 3650 天，SNI=${sni}）"
    cert_dir_prepare "$HY2_CERT_DIR"
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
    info "证书: ${HY2_CERT_DIR}/server.crt    私钥: ${HY2_CERT_DIR}/server.key"
}

# ────────────────────────────────────────────────────────────
#  带宽限制 / MTU 探测：交互询问
#  注意方向：服务端配置里的 up/down 与客户端相反
#    服务端 up（发出）= 客户端下载；服务端 down（接收）= 客户端上传
#  这里按「客户端实际速度」询问，写服务端配置时自动对调
# ────────────────────────────────────────────────────────────
hy2_ask_limits() {
    local v
    echo ""
    echo -e "  ${BOLD}带宽限制${NC}（按「客户端实际速度」填写，单位 Mbps，填 0 = 不限速）"
    echo -e "  ${YELLOW}⚠ 注意：服务端配置里的 up / down 和客户端是反的！${NC}"
    echo "    服务端 up（发出）= 客户端下载；服务端 down（接收）= 客户端上传。"
    echo "    这里直接填客户端的上传 / 下载速度，脚本会自动对调后写入服务端配置。"
    echo ""
    while true; do
        read -rp "  客户端上传带宽 Mbps（默认 50，0 = 不限）: " v
        v=${v:-50}
        if [[ "$v" =~ ^[0-9]+$ ]]; then HY2_UL_MBPS=$(( 10#$v )); break; fi
        warn "请输入非负整数（0 = 不限速）"
    done
    while true; do
        read -rp "  客户端下载带宽 Mbps（默认 200，0 = 不限）: " v
        v=${v:-200}
        if [[ "$v" =~ ^[0-9]+$ ]]; then HY2_DL_MBPS=$(( 10#$v )); break; fi
        warn "请输入非负整数（0 = 不限速）"
    done
    echo -e "  ${DIM}→ 服务端将写入: up ${HY2_DL_MBPS} mbps（= 客户端下载） / down ${HY2_UL_MBPS} mbps（= 客户端上传）${NC}"
    echo -e "  ${DIM}  限速只对 Brutal 生效：客户端必须声明自己的带宽，否则走 BBR，服务端限速不起作用。${NC}"
    echo -e "  ${DIM}  本脚本输出的 client.yaml 与 Clash 配置已带 bandwidth；用分享链接导入的客户端需自行在客户端里填写。${NC}"

    echo ""
    echo "  QUIC 路径 MTU 探测（Hysteria 2 不能指定具体 MTU 数值，只能开关探测）"
    echo "    默认保持开启（自动探测）。仅当链路丢大包、连上后卡住或速度异常时才建议关闭。"
    echo "    关闭后服务端与客户端需保持一致。"
    read -rp "  是否关闭 MTU 探测？[y/N]: " v
    if [[ "${v:-N}" =~ ^[Yy]$ ]]; then HY2_NO_PMTUD=1; else HY2_NO_PMTUD=0; fi
    return 0
}

# 服务端 config.yaml 里的 bandwidth / quic 段（up = 客户端下载，down = 客户端上传）
hy2_extra_config_block() {
    local srv_up=$HY2_DL_MBPS srv_down=$HY2_UL_MBPS
    if (( srv_up > 0 || srv_down > 0 )); then
        echo "bandwidth:"
        if (( srv_up   > 0 )); then echo "  up: ${srv_up} mbps    # 服务端发出 = 客户端下载"; fi
        if (( srv_down > 0 )); then echo "  down: ${srv_down} mbps    # 服务端接收 = 客户端上传"; fi
    fi
    if (( HY2_NO_PMTUD == 1 )); then
        if (( srv_up > 0 || srv_down > 0 )); then echo ""; fi
        echo "quic:"
        echo "  disablePathMTUDiscovery: true"
    fi
    return 0
}

# 客户端 client.yaml 里的 bandwidth / quic 段（客户端视角：up = 上传，down = 下载）
hy2_client_extra_block() {
    local up=$HY2_UL_MBPS down=$HY2_DL_MBPS
    if (( up > 0 || down > 0 )); then
        echo "bandwidth:"
        if (( up   > 0 )); then echo "  up: ${up} mbps"; fi
        if (( down > 0 )); then echo "  down: ${down} mbps"; fi
    fi
    if (( HY2_NO_PMTUD == 1 )); then
        if (( up > 0 || down > 0 )); then echo ""; fi
        echo "quic:"
        echo "  disablePathMTUDiscovery: true"
    fi
    return 0
}

hy2_bw_summary() {
    if (( HY2_UL_MBPS == 0 && HY2_DL_MBPS == 0 )); then
        printf '不限速'
        return 0
    fi
    local ul="${HY2_UL_MBPS} Mbps" dl="${HY2_DL_MBPS} Mbps"
    if (( HY2_UL_MBPS == 0 )); then ul="不限"; fi
    if (( HY2_DL_MBPS == 0 )); then dl="不限"; fi
    printf '客户端 上传 %s / 下载 %s（服务端配置写作 up %s / down %s，方向相反）' "$ul" "$dl" "$dl" "$ul"
    return 0
}

# ────────────────────────────────────────────────────────────
#  写入 config.yaml —— ACME 模式（ACME 数据目录 = HY2_ACME_DIR）
# ────────────────────────────────────────────────────────────
hy2_write_config_acme() {
    local domain=$1 email=$2 password=$3 port=$4 ca=$5
    mkdir -p "$HY2_CONF_DIR"
    cert_dir_prepare "$HY2_ACME_DIR"
    cat > "$HY2_CONF" <<EOF
listen: :${port}

acme:
  domains:
    - ${domain}
  email: ${email}
  ca: ${ca}
  dir: ${HY2_ACME_DIR}
  type: http

$(hy2_extra_config_block)

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
#  写入 config.yaml —— 自签名模式（证书 = HY2_CERT_DIR/server.crt）
# ────────────────────────────────────────────────────────────
hy2_write_config_selfsigned() {
    local password=$1 port=$2
    mkdir -p "$HY2_CONF_DIR"
    cat > "$HY2_CONF" <<EOF
listen: :${port}

tls:
  cert: ${HY2_CERT_DIR}/server.crt
  key:  ${HY2_CERT_DIR}/server.key

$(hy2_extra_config_block)

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
#  写入服务单元（systemd / OpenRC 自动选择）
# ────────────────────────────────────────────────────────────
hy2_write_service() {
    svc_write_unit "$HY2_SVC_NAME" "Hysteria 2 Server" "$HY2_CONF_DIR" "$HY2_BIN" \
        "server -c ${HY2_CONF}"
}

# ────────────────────────────────────────────────────────────
#  等待 ACME 证书申请完成（结果写入全局 HY2_CERT_FOUND）
# ────────────────────────────────────────────────────────────
hy2_wait_for_acme_cert() {
    local max_wait=90 f
    HY2_CERT_FOUND=""
    info "等待 Hysteria 2 自动申请证书（最多 ${max_wait}s）..."
    local i=0
    while (( i < max_wait )); do
        f=$(find "${HY2_ACME_DIR}" -name "*.crt" ! -name "*issuer*" 2>/dev/null | head -1 || true)
        if [[ -n "$f" ]]; then
            HY2_CERT_FOUND="$f"
            echo ""
            info "✅ 证书已就绪: $f"
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
               | sed -E 's/^.*=//' \
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
    echo -e "  ${BOLD}带宽限制        :${NC} ${CYAN}$(hy2_bw_summary)${NC}"
    if (( HY2_NO_PMTUD == 1 )); then
        echo -e "  ${BOLD}MTU 探测        :${NC} ${CYAN}已关闭（客户端也要设 quic.disablePathMTUDiscovery: true）${NC}"
    fi
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

$(hy2_client_extra_block)

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

$(hy2_client_extra_block)

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
                (( ++i ))
                echo -e "  ${CYAN}${BOLD}(${i})：${NC}"
                qrencode -t ansiutf8 "${link}"
            done
        else
            warn "未安装 qrencode，无法显示二维码（可运行: apt-get install -y qrencode）"
        fi
    fi

    # ── Clash / Mihomo 订阅格式（单节点）────────────────────
    local c_sni c_fp="" c_insecure=0
    if [[ "$tls_mode" == "1" ]]; then
        c_sni="$domain"
    else
        c_sni="$sni"
        c_fp="${_FP_COLON:-}"
        if [[ -z "$c_fp" ]]; then
            c_insecure=1
        fi
    fi
    if [[ -n "$yaml_host" ]]; then
        clash_emit "Hysteria2-${yaml_host}${HY2_NODE_TAG:-}" "$HY2_CLASH_FILE" \
            "$(clash_node_hy2 "Hysteria2-${yaml_host}${HY2_NODE_TAG:-}" "$yaml_host" "$port" "$password" "$c_sni" "$c_fp" "$HY2_UL_MBPS" "$HY2_DL_MBPS" "$c_insecure")"
    else
        warn "未能获取到服务器地址，无法生成 Clash 配置"
    fi

    # ── 服务管理命令 ────────────────────────────────────────
    box "服务管理"
    echo ""
    printf "  ${BOLD}%-14s${NC}  ${CYAN}%s${NC}\n" "启动服务"   "systemctl start   ${HY2_SVC_NAME:-hysteria-server}"
    printf "  ${BOLD}%-14s${NC}  ${CYAN}%s${NC}\n" "停止服务"   "systemctl stop    ${HY2_SVC_NAME:-hysteria-server}"
    printf "  ${BOLD}%-14s${NC}  ${CYAN}%s${NC}\n" "重启服务"   "systemctl restart ${HY2_SVC_NAME:-hysteria-server}"
    printf "  ${BOLD}%-14s${NC}  ${CYAN}%s${NC}\n" "查看状态"   "systemctl status  ${HY2_SVC_NAME:-hysteria-server}"
    printf "  ${BOLD}%-14s${NC}  ${CYAN}%s${NC}\n" "实时日志"   "journalctl -u ${HY2_SVC_NAME:-hysteria-server} -f"
    printf "  ${BOLD}%-14s${NC}  ${CYAN}%s${NC}\n" "编辑配置"   "nano ${HY2_CONF}"
    echo ""
    hr
    if systemctl is-active --quiet "${HY2_SVC_NAME:-hysteria-server}" 2>/dev/null; then
        echo -e "  服务状态:  ${GREEN}${BOLD}● 运行中 ✅${NC}"
    else
        echo -e "  服务状态:  ${RED}${BOLD}✗ 未运行${NC}"
        warn "服务可能启动失败，查看日志:"
        echo -e "  ${CYAN}journalctl -u ${HY2_SVC_NAME:-hysteria-server} --no-pager | tail -20${NC}"
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
        echo "  [1] 卸载后重新安装（会清除该协议的全部节点）"
        echo "  [2] 仅卸载，不重新安装"
        echo "  [3] 新增一个节点（保留现有节点）"
        echo "  [4] 退出，不做任何操作"
        echo ""
        read -rp "请选择 [1/2/3/4]（默认 1）: " choice
        case "${choice:-1}" in
            1) hy2_do_uninstall ;;
            2) hy2_do_uninstall; echo ""; info "卸载完成。"; exit 0 ;;
            3) hy2_add_node || true; return 0 ;;
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

    # ── 指定证书目录 ────────────────────────────────────────
    hy2_ask_cert_dir "$TLS_MODE"

    echo ""
    read -rp "  监听端口（默认 443）: " PORT
    PORT=${PORT:-443}

    DEFAULT_PASS=$(tr -dc 'A-Za-z0-9!@#^&*' </dev/urandom 2>/dev/null | head -c 20 \
                  || openssl rand -base64 16 | tr -d '=+/')
    read -rp "  认证密码（默认随机: ${DEFAULT_PASS}）: " PASSWORD
    PASSWORD=${PASSWORD:-$DEFAULT_PASS}

    hy2_ask_limits

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
    # 自签名模式：等待服务 active
    # ACME 模式：额外等待证书申请完成，再输出配置信息
    local CERT_FILE=""
    if [[ "$TLS_MODE" == "1" ]]; then
        echo ""
        info "Hysteria 2 正在后台向 ${ACME_CA} 申请证书..."
        info "使用 HTTP challenge，请确保 TCP 80 端口已开放"
        if hy2_wait_for_acme_cert; then
            CERT_FILE="$HY2_CERT_FOUND"
            info "✅ ACME 证书申请完成，继续输出配置信息"
        else
            warn "⚠ 未在限定时间内找到证书文件（申请可能仍在进行中）"
            warn "  可能原因: TCP 80 未开放 / 域名未正确解析 / CA 响应慢"
            warn "  查看日志: journalctl -u ${HY2_SVC_NAME:-hysteria-server} -f"
            CERT_FILE=""
        fi
    else
        # 自签名：等待服务 active（最多 10s）
        local waited=0
        while (( waited < 10 )); do
            systemctl is-active --quiet hysteria-server && break
            sleep 1; (( ++waited ))
        done
        if systemctl is-active --quiet hysteria-server; then
            info "服务已启动"
        else
            warn "服务启动可能失败，请查看日志: journalctl -u ${HY2_SVC_NAME:-hysteria-server} -f"
        fi
        CERT_FILE="${HY2_CERT_DIR}/server.crt"
    fi

    # ── 全部就绪后，统一输出配置信息 ────────────────────────
    hy2_print_client_info \
        "$TLS_MODE" "$DOMAIN" "$PASSWORD" "$PORT" "$SNI" \
        "$SERVER_IPV4" "$SERVER_IPV6" "$VERSION" "$CERT_FILE"
}

# ╔══════════════════════════════════════════════════════════╗
# ║            PART 3 — AnyTLS（sing-box 内核）              ║
# ╚══════════════════════════════════════════════════════════╝

AT_DIR="/etc/anytls-box"
AT_BIN="${AT_DIR}/sing-box"
AT_CONF="${AT_DIR}/config.json"
AT_SERVICE_NAME="anytls-box"
AT_SERVICE="$(svc_unit_path "$AT_SERVICE_NAME")"
AT_WANTS_LINK="/etc/systemd/system/multi-user.target.wants/${AT_SERVICE_NAME}.service"
AT_DOMAIN_RE='^[A-Za-z0-9]([A-Za-z0-9-]*[A-Za-z0-9])?(\.[A-Za-z0-9]([A-Za-z0-9-]*[A-Za-z0-9])?)+$'

# 证书目录：默认值固定不变；实际使用的 AT_CERT / AT_KEY / AT_ACME_DIR
# 会在安装时由用户指定，或在查看 / 卸载时从 config.json 读回
AT_CERT_DIR_DEFAULT="${AT_DIR}"          # 自签名：cert.pem / private.key
AT_ACME_DIR_DEFAULT="${AT_DIR}/acme"     # ACME：证书 / 账号 / 锁
AT_CERT="${AT_CERT_DIR_DEFAULT}/cert.pem"
AT_KEY="${AT_CERT_DIR_DEFAULT}/private.key"
AT_ACME_DIR="$AT_ACME_DIR_DEFAULT"

# 全局：供分享链接 / 二维码 / 客户端配置使用
AT_LINKS=()
AT_CERT_FILE=""
AT_SPKI_B64=""
AT_FP_COLON=""

# ────────────────────────────────────────────────────────────
#  小工具：URL 编码 / JSON 转义 / 端口占用检测 / 监听地址
# ────────────────────────────────────────────────────────────
at_url_enc() {
    local s="$1" i c out=""
    local LC_ALL=C
    for (( i=0; i<${#s}; i++ )); do
        c="${s:i:1}"
        case "$c" in
            [a-zA-Z0-9.~_-]) out+="$c" ;;
            *) out+=$(printf '%%%02X' "'$c") ;;
        esac
    done
    printf '%s' "$out"
}

at_json_escape() {
    local s="$1"
    s="${s//\\/\\\\}"
    s="${s//\"/\\\"}"
    printf '%s' "$s"
}

# YAML 标量：安全的纯文本原样输出（和常见写法一致），可能被误解析的才加双引号
# （Clash 配置输出共用，见文件顶部 clash_node_* 系列函数）
at_yaml_str() {
    local s="$1"
    if [[ "$s" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]] \
       && ! [[ "$s" =~ ^[-+]?[0-9][0-9._]*([eE][-+]?[0-9]+)?$ ]] \
       && ! [[ "$s" =~ ^0[xXoObB] ]] \
       && ! [[ "${s,,}" =~ ^(y|n|yes|no|true|false|on|off|null)$ ]]; then
        printf '%s' "$s"
    else
        printf '"%s"' "$(at_json_escape "$s")"
    fi
}

# server 字段：域名 / IPv4 原样输出，IPv6（含冒号）加引号
at_yaml_host() {
    if [[ "$1" == *:* ]]; then
        printf '"%s"' "$1"
    else
        printf '%s' "$1"
    fi
}

# 合法域名（且最后一段必须含字母，从而排除 1.2.3.4 这类 IP）
at_valid_domain() {
    local d=$1
    [[ "$d" =~ $AT_DOMAIN_RE ]] && [[ "${d##*.}" =~ [A-Za-z] ]]
}

# 读取已有 AnyTLS 配置里的监听端口（无 jq 时退回 sed）
at_conf_port() {
    [[ -f "$AT_CONF" ]] || return 0
    if command -v jq &>/dev/null; then
        jq -r '.inbounds[0].listen_port // empty' "$AT_CONF" 2>/dev/null || true
    else
        sed -nE 's/^[[:space:]]*"listen_port":[[:space:]]*([0-9]+).*$/\1/p' "$AT_CONF" | head -1 || true
    fi
    return 0
}

# 从已有 config.json 读回证书路径（安装时可能指定了自定义目录；不依赖 jq）
#   ACME 模式  → certificate_providers[0].data_directory → AT_ACME_DIR
#   自签名模式 → tls.certificate_path / key_path         → AT_CERT / AT_KEY
at_load_paths_from_conf() {
    [[ -f "$AT_CONF" ]] || return 0
    local v=""
    v=$(sed -nE 's/^[[:space:]]*"data_directory":[[:space:]]*"([^"]+)".*$/\1/p' "$AT_CONF" | head -1 || true)
    if [[ -n "$v" ]]; then AT_ACME_DIR="$v"; fi
    v=$(sed -nE 's/^[[:space:]]*"certificate_path":[[:space:]]*"([^"]+)".*$/\1/p' "$AT_CONF" | head -1 || true)
    if [[ -n "$v" ]]; then AT_CERT="$v"; fi
    v=$(sed -nE 's/^[[:space:]]*"key_path":[[:space:]]*"([^"]+)".*$/\1/p' "$AT_CONF" | head -1 || true)
    if [[ -n "$v" ]]; then AT_KEY="$v"; fi
    return 0
}

# 检测某个 TCP 端口是否处于 LISTEN 状态（纯 /proc 实现，不依赖额外工具）
at_port_in_use() {
    local hex
    local -a files=(/proc/net/tcp)
    hex=$(printf '%04X' "$1")
    [[ -r /proc/net/tcp6 ]] && files+=(/proc/net/tcp6)
    awk -v p=":${hex}\$" 'FNR>1 && $4=="0A" && $2 ~ p {f=1} END{exit !f}' "${files[@]}" 2>/dev/null
}

# 系统有 IPv6 就双栈监听，没有就只监听 IPv4
at_listen_addr() {
    if [[ -f /proc/net/if_inet6 ]] \
       && [[ "$(cat /proc/sys/net/ipv6/conf/all/disable_ipv6 2>/dev/null || echo 0)" != "1" ]]; then
        echo "::"
    else
        echo "0.0.0.0"
    fi
}

# 域名是否已解析到本机公网地址（ACME 预检，失败返回 1）
at_check_domain_dns() {
    local domain=$1 ipv4=$2 ipv6=$3 resolved ip
    resolved=$(getent ahosts "$domain" 2>/dev/null | awk '{print $1}' | sort -u || true)
    if [[ -z "$resolved" ]]; then
        warn "域名 ${domain} 当前没有解析记录，ACME 验证会失败"
        return 1
    fi
    for ip in "$ipv4" "$ipv6"; do
        [[ -n "$ip" ]] || continue
        if grep -qxF "$ip" <<< "$resolved"; then
            return 0
        fi
    done
    warn "域名 ${domain} 解析到: $(tr '\n' ' ' <<< "$resolved")"
    warn "与本机公网地址不一致（IPv4: ${ipv4:-无}  IPv6: ${ipv6:-无}）；若使用了 CDN/代理，ACME 验证很可能失败"
    return 1
}

# ────────────────────────────────────────────────────────────
#  检测是否已安装 / 卸载
# ────────────────────────────────────────────────────────────
at_is_installed() {
    [[ -f "$AT_BIN" || -f "$AT_SERVICE" ]]
}

at_do_uninstall() {
    # 参数 purge：彻底删除（含 ACME 证书缓存，不再询问）
    # 默认用于「重装」：会询问是否保留 ACME 证书缓存
    local mode="${1:-keep}" port="" keep_acme=0 ans t cdir
    step "卸载现有 AnyTLS 并清理文件"
    rm -f /root/clash_anytls_*.yaml "${PAUSED_DIR}"/at-*.json

    # 先读出监听端口（稍后撤销防火墙规则）和证书路径（可能是自定义目录）
    port=$(at_conf_port)
    at_load_paths_from_conf
    rm -f "$(dirname "$AT_CERT")"/cert-[0-9]*.pem "$(dirname "$AT_CERT")"/private-[0-9]*.key 2>/dev/null || true

    systemctl stop    "$AT_SERVICE_NAME" 2>/dev/null || true
    systemctl disable "$AT_SERVICE_NAME" 2>/dev/null || true
    pkill -f "^${AT_BIN} run" 2>/dev/null || true
    svc_remove_unit "$AT_SERVICE_NAME"
    systemctl daemon-reload 2>/dev/null || true
    systemctl reset-failed "$AT_SERVICE_NAME" 2>/dev/null || true

    # ACME 证书缓存在「重装」时默认保留：同一域名短时间内反复签发会触发 CA 频率限制
    if [[ "$mode" != "purge" && -d "$AT_ACME_DIR" ]]; then
        warn "检测到 ACME 证书缓存: ${AT_ACME_DIR}"
        echo "  同一域名反复重新签发会触发 CA 的频率限制（Let's Encrypt：同一组域名每周 5 张），默认保留。"
        read -rp "  是否同时删除 ACME 证书缓存？[y/N]: " ans
        [[ "${ans:-N}" =~ ^[Yy]$ ]] || keep_acme=1
    fi

    if [[ -e "$AT_CLASH_FILE" ]]; then
        info "删除 $AT_CLASH_FILE"
        rm -f "$AT_CLASH_FILE"
    fi

    if (( keep_acme == 1 )); then
        for t in "$AT_BIN" "$AT_CONF" "$AT_CERT" "$AT_KEY"; do
            if [[ -e "$t" ]]; then
                info "删除 $t"
                rm -f "$t"
            fi
        done
        info "已保留 ACME 证书缓存: ${AT_ACME_DIR}"
    elif [[ -e "$AT_DIR" ]]; then
        info "删除 $AT_DIR"
        rm -rf "$AT_DIR"
    fi

    # 自定义证书目录（不在 /etc/anytls-box 之内）：只删除脚本生成的内容，不 rm -rf 整个目录
    cdir="$(dirname "$AT_CERT")"
    if [[ "$cdir" != "$AT_DIR" && "$cdir" != "${AT_DIR}"/* ]]; then
        cert_dir_cleanup "$cdir" "$(basename "$AT_CERT")" "$(basename "$AT_KEY")"
    fi
    if (( keep_acme == 0 )) && [[ "$AT_ACME_DIR" != "${AT_DIR}"/* ]]; then
        cert_dir_cleanup "$AT_ACME_DIR" acme certificates locks ocsp
    fi

    if [[ -n "$port" ]]; then
        fw_close_tcp_port "$port"
    fi
    info "✅ 卸载清理完毕"
    return 0
}

# ────────────────────────────────────────────────────────────
#  架构 / 最新版本 / 依赖 / 下载
# ────────────────────────────────────────────────────────────
at_get_arch() {
    local m; m=$(uname -m)
    case "$m" in
        x86_64|amd64)    echo "amd64"   ;;
        aarch64|arm64)   echo "arm64"   ;;
        armv7*)          echo "armv7"   ;;
        i386|i686)       echo "386"     ;;
        riscv64)         echo "riscv64" ;;
        *)               error "sing-box 暂无适用于该 CPU 架构的发行包: $m" ;;
    esac
}

# 通过 /releases/latest 的跳转地址取版本号（不走 GitHub API，不受 API 频率限制）
at_get_latest_version() {
    local v
    v=$(curl -fsSL --max-time 15 -o /dev/null -w '%{url_effective}' \
        "https://github.com/SagerNet/sing-box/releases/latest" 2>/dev/null \
        | sed -E 's#.*/tag/v##') || true
    [[ "$v" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] \
        || error "无法获取 sing-box 最新版本，请检查网络（需要能访问 github.com）"
    echo "$v"
}

at_install_deps() {
    step "安装依赖（curl openssl tar jq qrencode）"

    if [[ "$OS_FAMILY" == debian || "$OS_FAMILY" == alpine ]]; then
        hy2_try_swap

        local i ok=0
        for i in 1 2 3; do
            if pkg_update; then ok=1; break; fi
            warn "软件源更新失败，重试 (${i}/3)..."
            sleep 2
        done
        (( ok == 0 )) && warn "软件源更新多次失败，尝试使用现有缓存继续安装"

        local fail=0
        hy2_apt_install_one curl    1 || fail=1
        hy2_apt_install_one openssl 1 || fail=1
        hy2_apt_install_one tar     1 || fail=1
        if [[ ! -s /etc/ssl/certs/ca-certificates.crt ]]; then
            hy2_apt_install_one ca-certificates 0 || true
        fi
        hy2_apt_install_one jq       0 || true
        hy2_apt_install_one qrencode 0 || true

        hy2_cleanup_swap

        if (( fail == 1 )); then
            error "依赖安装失败，请检查软件源与网络后重试"
        fi
    else
        pkg_install curl openssl tar ca-certificates 2>/dev/null || error "依赖安装失败"
        pkg_install jq qrencode 2>/dev/null || warn "jq / qrencode 未能安装（可选）"
    fi

    local c
    for c in curl openssl tar; do
        command -v "$c" &>/dev/null || error "缺少依赖命令：${c}"
    done
    info "依赖已就绪"
}

at_download() {
    local version=$1 arch=$2
    local base="https://github.com/SagerNet/sing-box/releases/download/v${version}"
    local tmp variant pkg ok=0

    step "下载 sing-box ${version} (${arch})"
    mkdir -p "$AT_DIR"
    tmp=$(mktemp -d)
    # 先用 glibc 版，跑不起来（极老/特殊系统）再退回静态链接的 musl 版
    # Alpine 使用 musl libc，直接选 musl 版
    local -a variants=(glibc musl)
    if [[ "$OS_FAMILY" == alpine ]]; then variants=(musl); fi
    for variant in "${variants[@]}"; do
        pkg="sing-box-${version}-linux-${arch}-${variant}.tar.gz"
        info "URL: ${base}/${pkg}"
        if curl -fL --retry 3 --progress-bar -o "${tmp}/sb.tar.gz" "${base}/${pkg}" \
           && tar xzf "${tmp}/sb.tar.gz" -C "$tmp" \
           && install -m 755 "${tmp}/sing-box-${version}-linux-${arch}-${variant}/sing-box" "$AT_BIN"; then
            if "$AT_BIN" version &>/dev/null; then
                ok=1
                info "✅ 已安装 ${variant} 版本 → ${AT_BIN}"
                break
            fi
            warn "${variant} 版本无法在当前系统运行，尝试下一个版本..."
        else
            warn "${variant} 版本下载或解压失败"
        fi
    done
    rm -rf "$tmp"
    (( ok == 1 )) || error "sing-box 下载失败，请检查网络或手动下载: ${base}/"
}

# ────────────────────────────────────────────────────────────
#  询问证书目录
#    自签名：证书 / 私钥（cert.pem / private.key）生成到该目录
#    ACME  ：sing-box 把申请到的证书、账号信息存放在该目录（续期也用它）
#  结果写入全局 AT_CERT / AT_KEY / AT_ACME_DIR
# ────────────────────────────────────────────────────────────
at_ask_cert_dir() {
    local mode=$1
    echo ""
    if [[ "$mode" == "1" ]]; then
        echo -e "  ${BOLD}ACME 证书目录${NC}"
        echo "  sing-box 申请到的证书、ACME 账号信息都保存在这里，到期续签也使用该目录。"
        ask_cert_dir "ACME 证书目录" "$AT_ACME_DIR_DEFAULT"
        AT_ACME_DIR="$CERT_DIR_RESULT"
    else
        echo -e "  ${BOLD}自签名证书目录${NC}"
        echo "  生成的证书 cert.pem 与私钥 private.key 将放在这里。"
        ask_cert_dir "自签名证书目录" "$AT_CERT_DIR_DEFAULT"
        AT_CERT="${CERT_DIR_RESULT}/cert.pem"
        AT_KEY="${CERT_DIR_RESULT}/private.key"
    fi
    return 0
}

# ────────────────────────────────────────────────────────────
#  生成自签名 TLS 证书（输出到 AT_CERT / AT_KEY 所在目录）
# ────────────────────────────────────────────────────────────
at_gen_selfsigned_cert() {
    local sni=$1
    step "生成自签名 TLS 证书（P-256，有效期 3650 天，SNI=${sni}）"
    mkdir -p "$AT_DIR"
    cert_dir_prepare "$(dirname "$AT_CERT")"
    openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:P-256 \
        -keyout "$AT_KEY" -out "$AT_CERT" \
        -days 3650 -nodes \
        -subj "/CN=${sni}" \
        -addext "subjectAltName=DNS:${sni}" \
        2>/dev/null || \
    openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:P-256 \
        -keyout "$AT_KEY" -out "$AT_CERT" \
        -days 3650 -nodes \
        -subj "/CN=${sni}" \
        2>/dev/null
    chmod 600 "$AT_KEY"
    chmod 644 "$AT_CERT"
    info "✅ 证书生成完毕（CN=${sni}，客户端须配置 sni: ${sni}）"
    info "证书: ${AT_CERT}    私钥: ${AT_KEY}"
}

# ────────────────────────────────────────────────────────────
#  写入 config.json —— 自签名模式
# ────────────────────────────────────────────────────────────
at_write_config_selfsigned() {
    local password=$1 port=$2 sni=$3 listen=$4
    mkdir -p "$AT_DIR"
    cat > "$AT_CONF" <<EOF
{
  "log": { "level": "info", "timestamp": true },
  "inbounds": [
    {
      "type": "anytls",
      "tag": "anytls-in",
      "listen": "${listen}",
      "listen_port": ${port},
      "users": [
        { "name": "user1", "password": "$(at_json_escape "$password")" }
      ],
      "tls": {
        "enabled": true,
        "server_name": "${sni}",
        "certificate_path": "${AT_CERT}",
        "key_path": "${AT_KEY}"
      }
    }
  ],
  "outbounds": [
    { "type": "direct", "tag": "direct" }
  ]
}
EOF
    chmod 600 "$AT_CONF"
}

# ────────────────────────────────────────────────────────────
#  写入 config.json —— ACME 模式（数据目录 = AT_ACME_DIR）
#  （sing-box 1.14+ 的 certificate_providers 写法；旧的 tls.acme 内联写法已弃用）
# ────────────────────────────────────────────────────────────
at_write_config_acme() {
    local domain=$1 email=$2 password=$3 port=$4 ca=$5 listen=$6
    mkdir -p "$AT_DIR"
    cert_dir_prepare "$AT_ACME_DIR"
    cat > "$AT_CONF" <<EOF
{
  "log": { "level": "info", "timestamp": true },
  "certificate_providers": [
    {
      "type": "acme",
      "tag": "acme-cert",
      "domain": ["${domain}"],
      "data_directory": "${AT_ACME_DIR}",
      "email": "$(at_json_escape "$email")",
      "provider": "${ca}"
    }
  ],
  "inbounds": [
    {
      "type": "anytls",
      "tag": "anytls-in",
      "listen": "${listen}",
      "listen_port": ${port},
      "users": [
        { "name": "user1", "password": "$(at_json_escape "$password")" }
      ],
      "tls": {
        "enabled": true,
        "server_name": "${domain}",
        "certificate_provider": "acme-cert"
      }
    }
  ],
  "outbounds": [
    { "type": "direct", "tag": "direct" }
  ]
}
EOF
    chmod 600 "$AT_CONF"
}

# ────────────────────────────────────────────────────────────
#  写入服务单元（systemd / OpenRC 自动选择）
# ────────────────────────────────────────────────────────────
at_write_service() {
    svc_write_unit "$AT_SERVICE_NAME" "AnyTLS Server (sing-box)" "$AT_DIR" "$AT_BIN" \
        "run -c ${AT_CONF} -D ${AT_DIR}"
}

# ────────────────────────────────────────────────────────────
#  配置防火墙（ufw / firewalld / iptables）
# ────────────────────────────────────────────────────────────
at_configure_firewall() {
    local port=$1 acme=$2 p
    local -a ports=("$port")
    [[ "$acme" == "1" ]] && ports+=(80)

    step "配置防火墙"
    if command -v ufw &>/dev/null && ufw status 2>/dev/null | grep -q "Status: active"; then
        for p in "${ports[@]}"; do
            ufw allow "${p}/tcp" comment "AnyTLS" >/dev/null 2>&1 || true
            info "ufw 已放行端口 ${p}/tcp"
        done
    elif command -v firewall-cmd &>/dev/null && firewall-cmd --state &>/dev/null; then
        for p in "${ports[@]}"; do
            firewall-cmd --permanent --add-port="${p}/tcp" >/dev/null 2>&1 || true
            info "firewalld 已放行端口 ${p}/tcp"
        done
        firewall-cmd --reload >/dev/null 2>&1 || true
    elif command -v iptables &>/dev/null; then
        for p in "${ports[@]}"; do
            iptables -C INPUT -p tcp --dport "$p" -j ACCEPT 2>/dev/null \
                || iptables -I INPUT -p tcp --dport "$p" -j ACCEPT 2>/dev/null || true
            if command -v ip6tables &>/dev/null; then
                ip6tables -C INPUT -p tcp --dport "$p" -j ACCEPT 2>/dev/null \
                    || ip6tables -I INPUT -p tcp --dport "$p" -j ACCEPT 2>/dev/null || true
            fi
            info "iptables 已放行端口 ${p}/tcp（重启后失效，如需持久化请自行保存规则）"
        done
    else
        warn "未检测到防火墙，请手动放行端口 ${ports[*]}（Alpine 可执行 apk add iptables 后重试）"
    fi
    warn "如果云服务商控制台有安全组/防火墙，请同时放行 TCP ${ports[*]}"
}

# ────────────────────────────────────────────────────────────
#  等待 ACME 证书申请完成（结果写入全局 AT_CERT_FILE，避免命令替换吞掉输出）
# ────────────────────────────────────────────────────────────
at_wait_for_acme_cert() {
    local max_wait=90 waited=0 f
    AT_CERT_FILE=""
    info "等待 sing-box 向 CA 申请证书（最多 ${max_wait}s）..."
    while (( waited < max_wait )); do
        f=$(find "$AT_ACME_DIR" -type f -name '*.crt' ! -name '*issuer*' -print -quit 2>/dev/null || true)
        if [[ -n "$f" ]]; then
            AT_CERT_FILE="$f"
            echo ""
            info "✅ 证书已就绪: ${f}"
            return 0
        fi
        sleep 2
        waited=$(( waited + 2 ))
        printf "."
    done
    echo ""
    return 1
}

# ────────────────────────────────────────────────────────────
#  输出证书指纹（自签名 / ACME 都可用），并记录公钥 pin 供客户端配置使用
# ────────────────────────────────────────────────────────────
at_print_cert_fingerprint() {
    local cert_file=$1
    AT_SPKI_B64=""
    AT_FP_COLON=""
    if [[ ! -f "$cert_file" ]]; then
        warn "证书文件不存在，跳过指纹输出: $cert_file"
        return 0
    fi

    box "TLS 证书指纹"

    local fp_colon spki
    fp_colon=$(openssl x509 -in "$cert_file" -noout -fingerprint -sha256 2>/dev/null \
               | sed -E 's/^.*=//' | tr '[:lower:]' '[:upper:]') || fp_colon=""
    spki=$(openssl x509 -in "$cert_file" -noout -pubkey 2>/dev/null \
           | openssl pkey -pubin -outform DER 2>/dev/null \
           | openssl dgst -sha256 -binary 2>/dev/null \
           | base64 -w0 2>/dev/null) || spki=""
    AT_SPKI_B64="$spki"
    AT_FP_COLON="$fp_colon"

    echo ""
    printf "  ${BOLD}证书 SHA256 指纹${NC}  ${DIM}（十六进制·冒号分隔）${NC}\n"
    echo   -e "           ${CYAN}${fp_colon:-（计算失败）}${NC}"
    echo ""
    printf "  ${BOLD}公钥 SHA256${NC}       ${DIM}（Base64，sing-box 的 certificate_public_key_sha256）${NC}\n"
    echo   -e "           ${CYAN}${spki:-（计算失败）}${NC}"
    hr
    echo -e "  ${BOLD}证书主体  :${NC} $(openssl x509 -in "$cert_file" -noout -subject 2>/dev/null | sed 's/subject=//')"
    echo -e "  ${BOLD}签发者    :${NC} $(openssl x509 -in "$cert_file" -noout -issuer  2>/dev/null | sed 's/issuer=//')"
    echo -e "  ${BOLD}有效期起  :${NC} $(openssl x509 -in "$cert_file" -noout -startdate 2>/dev/null | sed 's/notBefore=//')"
    echo -e "  ${BOLD}有效期止  :${NC} $(openssl x509 -in "$cert_file" -noout -enddate   2>/dev/null | sed 's/notAfter=//')"
    hr
}

# ────────────────────────────────────────────────────────────
#  输出 anytls:// 分享链接（同时收集到 AT_LINKS，供二维码使用）
#  注意：标准 anytls:// 链接无法携带公钥 pin，自签名模式只能用 insecure=1
# ────────────────────────────────────────────────────────────
at_print_links() {
    local tls_mode=$1 domain=$2 password=$3 port=$4 sni=$5 ipv4=$6 ipv6=$7
    local enc_pw uri
    enc_pw=$(at_url_enc "$password")
    AT_LINKS=()

    if [[ "$tls_mode" == "1" ]]; then
        echo -e "  ${DIM}[域名]${NC}"
        uri="anytls://${enc_pw}@${domain}:${port}/#AnyTLS-${domain}"
        echo -e "  ${CYAN}${uri}${NC}"
        AT_LINKS+=("$uri")
    else
        if [[ -n "$ipv4" ]]; then
            echo -e "  ${DIM}[IPv4]${NC}"
            uri="anytls://${enc_pw}@${ipv4}:${port}/?sni=${sni}&insecure=1#AnyTLS-${ipv4}"
            echo -e "  ${CYAN}${uri}${NC}"
            AT_LINKS+=("$uri")
        fi
        if [[ -n "$ipv6" ]]; then
            echo -e "  ${DIM}[IPv6]${NC}"
            uri="anytls://${enc_pw}@[${ipv6}]:${port}/?sni=${sni}&insecure=1#AnyTLS-v6-${ipv6}"
            echo -e "  ${CYAN}${uri}${NC}"
            AT_LINKS+=("$uri")
        fi
        if [[ -z "$ipv4" && -z "$ipv6" ]]; then
            warn "未能获取到任何公网 IP，分享链接无法生成"
        fi
    fi
}

at_print_qr() {
    (( ${#AT_LINKS[@]} > 0 )) || return 0
    if command -v qrencode &>/dev/null; then
        echo ""
        local i=0 link
        for link in "${AT_LINKS[@]}"; do
            i=$(( i + 1 ))
            echo -e "  ${CYAN}${BOLD}二维码 (${i})：${NC}"
            qrencode -t ansiutf8 "${link}"
        done
    else
        warn "未安装 qrencode，无法显示二维码（可运行: apt-get install -y qrencode）"
    fi
}

# ────────────────────────────────────────────────────────────
#  输出 sing-box 客户端 outbound + Clash / Mihomo 订阅格式配置（单节点）
# ────────────────────────────────────────────────────────────
at_print_client_snippets() {
    local tls_mode=$1 host=$2 password=$3 port=$4 sni=$5
    local pw; pw=$(at_json_escape "$password")

    echo -e "${BOLD}# sing-box 客户端 outbound：${NC}"
    printf '%b' "$CYAN"
    if [[ "$tls_mode" == "2" && -n "$AT_SPKI_B64" ]]; then
        cat <<EOF
{
  "type": "anytls",
  "tag": "anytls-out",
  "server": "${host}",
  "server_port": ${port},
  "password": "${pw}",
  "tls": {
    "enabled": true,
    "server_name": "${sni}",
    "certificate_public_key_sha256": ["${AT_SPKI_B64}"]
  }
}
EOF
    elif [[ "$tls_mode" == "2" ]]; then
        cat <<EOF
{
  "type": "anytls",
  "tag": "anytls-out",
  "server": "${host}",
  "server_port": ${port},
  "password": "${pw}",
  "tls": {
    "enabled": true,
    "server_name": "${sni}",
    "insecure": true
  }
}
EOF
    else
        cat <<EOF
{
  "type": "anytls",
  "tag": "anytls-out",
  "server": "${host}",
  "server_port": ${port},
  "password": "${pw}",
  "tls": {
    "enabled": true,
    "server_name": "${sni}"
  }
}
EOF
    fi
    printf '%b' "$NC"
    if [[ "$tls_mode" == "2" && -n "$AT_SPKI_B64" ]]; then
        echo -e "  ${DIM}↑ 固定服务器证书公钥（不用关闭校验，更安全）；客户端不支持时可改成 \"insecure\": true${NC}"
    fi

    clash_emit "AnyTLS-${host}" "$AT_CLASH_FILE" \
        "$(clash_node_anytls "AnyTLS-${host}" "$host" "$port" "$password" "$sni" "$tls_mode" "${AT_FP_COLON:-}")"
}

# ────────────────────────────────────────────────────────────
#  输出客户端配置 & 链接（AnyTLS）
# ────────────────────────────────────────────────────────────
at_print_client_info() {
    local tls_mode=$1 domain=$2 password=$3 port=$4 sni=$5
    local server_ipv4=$6 server_ipv6=$7 version=$8 cert_file=$9

    box "安装完成！"
    echo ""

    hr
    echo -e "  ${BOLD}sing-box 版本   :${NC} ${CYAN}${version}${NC}"
    [[ -n "$server_ipv4" ]] && echo -e "  ${BOLD}公网 IPv4       :${NC} ${CYAN}${server_ipv4}${NC}"
    [[ -n "$server_ipv6" ]] && echo -e "  ${BOLD}公网 IPv6       :${NC} ${CYAN}${server_ipv6}${NC}"
    echo -e "  ${BOLD}端口            :${NC} ${CYAN}${port}/tcp${NC}"
    if [[ "$tls_mode" == "1" ]]; then
        echo -e "  ${BOLD}域名            :${NC} ${CYAN}${domain}${NC}"
        echo -e "  ${BOLD}TLS 模式        :${NC} ${CYAN}ACME 自动证书${NC}"
    else
        echo -e "  ${BOLD}SNI（伪装域名）  :${NC} ${CYAN}${sni}${NC}"
        echo -e "  ${BOLD}TLS 模式        :${NC} ${CYAN}自签名证书${NC}"
    fi
    echo -e "  ${BOLD}密码            :${NC} ${CYAN}${password}${NC}"
    echo -e "  ${BOLD}UDP             :${NC} ${CYAN}UDP over TCP（非原生 UDP）${NC}"
    hr

    # ── 证书目录 ────────────────────────────────────────────
    echo ""
    echo -e "  ${BOLD}📁 证书目录${NC}"
    hr
    if [[ "$tls_mode" == "1" ]]; then
        echo -e "  根目录 : ${CYAN}${AT_ACME_DIR}${NC}"
        [[ -n "$cert_file" ]] && echo -e "  实际证书: ${CYAN}${cert_file}${NC}"
        echo -e "  ${DIM}  ✓ 全程自动管理，到期前自动续签${NC}"
    else
        echo -e "  目录   : ${CYAN}$(dirname "$AT_CERT")/${NC}"
        echo -e "  证书   : ${CYAN}${AT_CERT}${NC}"
        echo -e "  私钥   : ${CYAN}${AT_KEY}${NC}"
    fi
    hr

    # ── 证书指纹 ────────────────────────────────────────────
    if [[ "$tls_mode" == "2" ]]; then
        at_print_cert_fingerprint "$AT_CERT"
    elif [[ -n "$cert_file" && -f "$cert_file" ]]; then
        at_print_cert_fingerprint "$cert_file"
    else
        echo ""
        warn "ACME 证书尚未生成，证书就绪后可手动查看:"
        echo -e "  ${CYAN}find ${AT_ACME_DIR} -name '*.crt' ! -name '*issuer*'${NC}"
        echo -e "  ${CYAN}journalctl -u ${AT_SERVICE_NAME} --no-pager | grep -i acme | tail -20${NC}"
        echo ""
    fi

    # ── 分享链接 ────────────────────────────────────────────
    box "客户端配置"
    echo ""
    echo -e "${BOLD}# 导入链接（Shadowrocket / NekoBox / sing-box 等）：${NC}"
    echo ""
    at_print_links "$tls_mode" "$domain" "$password" "$port" "$sni" "$server_ipv4" "$server_ipv6"
    at_print_qr

    # ── 客户端配置片段（含 Clash / Mihomo 订阅格式）─────────
    local host
    if [[ "$tls_mode" == "1" ]]; then
        host="$domain"
    else
        host="${server_ipv4:-${server_ipv6}}"
    fi
    echo ""
    at_print_client_snippets "$tls_mode" "$host" "$password" "$port" "$sni"
    echo ""
    echo -e "  ${DIM}UDP：sing-box 客户端自动走 UDP over TCP；Clash/Mihomo 节点需保持 udp: true${NC}"

    # ── 服务管理命令 ────────────────────────────────────────
    box "服务管理"
    echo ""
    printf "  ${BOLD}%-14s${NC}  ${CYAN}%s${NC}\n" "启动服务"   "systemctl start   ${AT_SERVICE_NAME}"
    printf "  ${BOLD}%-14s${NC}  ${CYAN}%s${NC}\n" "停止服务"   "systemctl stop    ${AT_SERVICE_NAME}"
    printf "  ${BOLD}%-14s${NC}  ${CYAN}%s${NC}\n" "重启服务"   "systemctl restart ${AT_SERVICE_NAME}"
    printf "  ${BOLD}%-14s${NC}  ${CYAN}%s${NC}\n" "查看状态"   "systemctl status  ${AT_SERVICE_NAME}"
    printf "  ${BOLD}%-14s${NC}  ${CYAN}%s${NC}\n" "实时日志"   "journalctl -u ${AT_SERVICE_NAME} -f"
    printf "  ${BOLD}%-14s${NC}  ${CYAN}%s${NC}\n" "编辑配置"   "nano ${AT_CONF}"
    echo ""
    hr
    if systemctl is-active --quiet "$AT_SERVICE_NAME" 2>/dev/null; then
        echo -e "  服务状态:  ${GREEN}${BOLD}● 运行中 ✅${NC}"
    else
        echo -e "  服务状态:  ${RED}${BOLD}✗ 未运行${NC}"
        warn "服务可能启动失败，查看日志:"
        echo -e "  ${CYAN}journalctl -u ${AT_SERVICE_NAME} --no-pager | tail -20${NC}"
    fi
    hr
    echo ""
}

# ────────────────────────────────────────────────────────────
#  查看已有 AnyTLS 节点配置（主菜单「查看配置」里调用）
# ────────────────────────────────────────────────────────────
show_anytls_existing_config() {
    local config="$AT_CONF"
    [[ -f "$config" ]] || return 1

    # 证书目录可能是安装时自定义的，先从配置里读回来
    at_load_paths_from_conf
    AT_SPKI_B64=""
    AT_FP_COLON=""

    box "当前 AnyTLS 节点"
    echo -e "  ${BOLD}配置文件${NC}: ${CYAN}${config}${NC}"

    if ! command -v jq &>/dev/null; then
        warn "未找到 jq，无法提取摘要，以下显示原始配置文件"
        sed -n '1,120p' "$config"
        return 0
    fi

    local port password sni domain="" tls_mode cert_file="" cert_dir status
    local server_ipv4 server_ipv6
    port=$(jq -r '.inbounds[0].listen_port // empty' "$config" 2>/dev/null || true)
    password=$(jq -r '.inbounds[0].users[0].password // empty' "$config" 2>/dev/null || true)
    sni=$(jq -r '.inbounds[0].tls.server_name // empty' "$config" 2>/dev/null || true)
    if jq -e '.certificate_providers[0]' "$config" &>/dev/null; then
        tls_mode="1"
        domain=$(jq -r '.certificate_providers[0].domain[0] // empty' "$config" 2>/dev/null || true)
        cert_dir="$AT_ACME_DIR"
        cert_file=$(find "$AT_ACME_DIR" -type f -name '*.crt' ! -name '*issuer*' -print -quit 2>/dev/null || true)
    else
        tls_mode="2"
        cert_file=$(jq -r '.inbounds[0].tls.certificate_path // empty' "$config" 2>/dev/null || true)
        cert_dir="$(dirname "${cert_file:-$AT_CERT}")"
    fi

    if systemctl is-active --quiet "$AT_SERVICE_NAME" 2>/dev/null; then
        status="运行中"
    else
        status="未运行"
    fi
    printf "  ${BOLD}服务状态${NC}: %s\n" "$status"
    printf "  ${BOLD}端口${NC}:       %s\n" "${port:-未知}"
    printf "  ${BOLD}认证密码${NC}:   %s\n" "${password:-未知}"
    if [[ "$tls_mode" == "1" ]]; then
        printf "  ${BOLD}TLS 模式${NC}:   %s\n" "ACME"
        printf "  ${BOLD}域名${NC}:       %s\n" "${domain:-未知}"
    else
        printf "  ${BOLD}TLS 模式${NC}:   %s\n" "自签名"
        printf "  ${BOLD}SNI${NC}:         %s\n" "${sni:-未知}"
    fi
    printf "  ${BOLD}证书目录${NC}:   %s\n" "$cert_dir"
    [[ -n "$cert_file" ]] && printf "  ${BOLD}证书${NC}:       %s\n" "$cert_file"

    server_ipv4=$(hy2_get_ipv4 2>/dev/null || true)
    server_ipv6=$(hy2_get_ipv6 2>/dev/null || true)
    echo ""
    if [[ "$tls_mode" == "2" && -n "$cert_file" && -f "$cert_file" ]]; then
        at_print_cert_fingerprint "$cert_file"
    fi

    if [[ -n "$password" && -n "$port" ]]; then
        at_print_links "$tls_mode" "$domain" "$password" "$port" "$sni" "$server_ipv4" "$server_ipv6"
        at_print_qr
    else
        warn "未能从配置中提取端口/密码，无法生成分享链接"
    fi

    local host=""
    if [[ "$tls_mode" == "1" ]]; then
        host="$domain"
    else
        host="${server_ipv4:-$server_ipv6}"
    fi
    if [[ -n "$host" && -n "$password" && -n "$port" ]]; then
        echo ""
        at_print_client_snippets "$tls_mode" "$host" "$password" "$port" "${sni:-$domain}"
    fi

    echo ""
    echo -e "  ${BOLD}原始配置（前 60 行）:${NC}"
    sed -n '1,60p' "$config"
}

# ────────────────────────────────────────────────────────────
#  AnyTLS 主流程入口
# ────────────────────────────────────────────────────────────
install_anytls() {
    clear
    box "AnyTLS 一键安装脚本"
    echo -e "  内核: ${CYAN}sing-box${NC}（anytls inbound）   协议: ${CYAN}https://github.com/anytls/anytls-go${NC}"
    echo -e "  ${DIM}基于 TCP + TLS；UDP 通过 UDP over TCP 转发（不是原生 UDP）${NC}"
    echo ""

    # ── 已安装检测 ──────────────────────────────────────────
    if at_is_installed; then
        echo ""
        warn "检测到系统已安装 AnyTLS"
        echo ""
        echo "  [1] 卸载后重新安装（会清除该协议的全部节点）"
        echo "  [2] 仅卸载，不重新安装"
        echo "  [3] 新增一个节点（保留现有节点）"
        echo "  [4] 退出，不做任何操作"
        echo ""
        local choice
        read -rp "请选择 [1/2/3/4]（默认 1）: " choice
        case "${choice:-1}" in
            1) at_do_uninstall ;;
            2) at_do_uninstall; echo ""; info "卸载完成。"; exit 0 ;;
            3) at_add_node || true; return 0 ;;
            *) info "已取消，退出。"; exit 0 ;;
        esac
    fi

    # ── 收集安装参数 ────────────────────────────────────────
    box "配置参数"
    echo ""

    local TLS_MODE DOMAIN="" EMAIL="" ACME_CA="letsencrypt" SNI="" PORT PASSWORD ans
    local email_re='^[^@"[:space:]]+@[^@"[:space:]]+\.[^@"[:space:]]+$'

    echo "  TLS 证书模式："
    echo "    [1] ACME 自动申请（sing-box 自动向 CA 申请 + 自动续期）"
    echo "        要求：有效域名已解析到本机 + TCP 80 端口可访问"
    echo "    [2] 自签名证书（无需域名，IP 直连，客户端需 insecure 或固定公钥）"
    echo ""
    read -rp "  请选择 [1/2]（默认 2）: " TLS_MODE
    TLS_MODE=${TLS_MODE:-2}
    [[ "$TLS_MODE" == "1" || "$TLS_MODE" == "2" ]] || error "无效的证书模式：${TLS_MODE}"

    echo ""
    info "正在检测服务器公网地址..."
    local SERVER_IPV4 SERVER_IPV6
    SERVER_IPV4=$(hy2_get_ipv4)
    SERVER_IPV6=$(hy2_get_ipv6)
    [[ -n "$SERVER_IPV4" ]] && info "公网 IPv4 : ${SERVER_IPV4}" || warn "未检测到公网 IPv4"
    [[ -n "$SERVER_IPV6" ]] && info "公网 IPv6 : ${SERVER_IPV6}" || info "未检测到公网 IPv6（单栈服务器）"

    if [[ "$TLS_MODE" == "1" ]]; then
        echo ""
        read -rp "  请输入域名（需已 DNS 解析到本机 IP）: " DOMAIN
        DOMAIN=$(echo "$DOMAIN" | sed -E 's|^https?://||;s|/.*||;s/[[:space:]]//g')
        at_valid_domain "$DOMAIN" || error "域名格式不正确：${DOMAIN:-（空）}"
        read -rp "  请输入邮箱（ACME 账号注册 + 到期通知）: " EMAIL
        EMAIL=$(echo "$EMAIL" | sed -E 's/[[:space:]]//g')
        [[ "$EMAIL" =~ $email_re ]] || error "邮箱格式不正确：${EMAIL:-（空）}"
        echo ""
        echo "  证书签发机构："
        echo "    [1] Let's Encrypt（默认，推荐）"
        echo "    [2] ZeroSSL"
        local ca_choice
        read -rp "  请选择 [1/2]（默认 1）: " ca_choice
        [[ "${ca_choice:-1}" == "2" ]] && ACME_CA="zerossl" || ACME_CA="letsencrypt"

        if ! at_check_domain_dns "$DOMAIN" "$SERVER_IPV4" "$SERVER_IPV6"; then
            read -rp "  域名解析检查未通过，仍要继续吗？[y/N]: " ans
            [[ "${ans:-N}" =~ ^[Yy]$ ]] || exit 1
        fi
        if at_port_in_use 80; then
            warn "TCP 80 端口当前已被占用，ACME 的 HTTP 验证可能会失败"
            read -rp "  仍要继续吗？[y/N]: " ans
            [[ "${ans:-N}" =~ ^[Yy]$ ]] || exit 1
        fi
    else
        echo ""
        echo -e "  ${BOLD}SNI 伪装域名设置${NC}"
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
        at_valid_domain "$SNI" || error "SNI 必须是合法域名（不能是 IP 地址）：${SNI:-（空）}"
        info "SNI 设置为: ${SNI}"
    fi

    # ── 指定证书目录 ────────────────────────────────────────
    at_ask_cert_dir "$TLS_MODE"

    echo ""
    while true; do
        read -rp "  监听端口（默认 443，TCP）: " PORT
        PORT=${PORT:-443}
        if ! [[ "$PORT" =~ ^[0-9]+$ ]] || (( 10#$PORT < 1 || 10#$PORT > 65535 )); then
            warn "端口无效，请输入 1-65535 之间的数字"
            continue
        fi
        PORT=$(( 10#$PORT ))
        if at_port_in_use "$PORT"; then
            warn "TCP 端口 ${PORT} 当前已被占用（可能是 Xray REALITY 等其它服务）"
            read -rp "  仍要使用该端口吗？[y/N]: " ans
            [[ "${ans:-N}" =~ ^[Yy]$ ]] || continue
        fi
        break
    done

    local DEFAULT_PASS
    DEFAULT_PASS=$(head -c 16 /dev/urandom | od -An -tx1 | tr -d ' \n')
    read -rp "  认证密码（默认随机: ${DEFAULT_PASS}）: " PASSWORD
    PASSWORD=${PASSWORD:-$DEFAULT_PASS}

    # ── 开始安装 ────────────────────────────────────────────
    at_install_deps

    local ARCH VERSION LISTEN
    ARCH=$(at_get_arch)
    VERSION=$(at_get_latest_version)
    LISTEN=$(at_listen_addr)
    info "架构: ${ARCH}  |  sing-box 最新版本: ${VERSION}  |  监听: ${LISTEN}"

    at_download "$VERSION" "$ARCH"

    step "写入服务端配置"
    if [[ "$TLS_MODE" == "1" ]]; then
        at_write_config_acme "$DOMAIN" "$EMAIL" "$PASSWORD" "$PORT" "$ACME_CA" "$LISTEN"
        info "配置文件: ${AT_CONF}"
        info "ACME 证书目录: ${AT_ACME_DIR}（启动后自动申请）"
    else
        at_gen_selfsigned_cert "$SNI"
        at_write_config_selfsigned "$PASSWORD" "$PORT" "$SNI" "$LISTEN"
        info "配置文件: ${AT_CONF}"
        info "证书目录: $(dirname "$AT_CERT")"
    fi

    step "校验配置"
    "$AT_BIN" check -c "$AT_CONF" || error "配置校验失败，请检查 ${AT_CONF}"
    info "✅ 配置校验通过"

    at_configure_firewall "$PORT" "$([[ "$TLS_MODE" == "1" ]] && echo 1 || echo 0)"

    step "启动 AnyTLS 服务"
    at_write_service
    systemctl daemon-reload
    systemctl enable "$AT_SERVICE_NAME" >/dev/null 2>&1
    systemctl restart "$AT_SERVICE_NAME" \
        || error "服务启动失败，请执行 journalctl -u ${AT_SERVICE_NAME} -n 50 查看日志"

    # ── 等待服务就绪 ─────────────────────────────────────────
    # 自签名模式：确认服务 active
    # ACME 模式：额外等待证书申请完成，再输出配置信息
    local waited=0
    while (( waited < 10 )); do
        systemctl is-active --quiet "$AT_SERVICE_NAME" && break
        sleep 1
        waited=$(( waited + 1 ))
    done
    sleep 1
    if systemctl is-active --quiet "$AT_SERVICE_NAME"; then
        info "服务已启动"
    else
        warn "服务启动可能失败，请查看日志: journalctl -u ${AT_SERVICE_NAME} -f"
    fi

    AT_CERT_FILE=""
    if [[ "$TLS_MODE" == "1" ]]; then
        echo ""
        info "sing-box 正在后台向 ${ACME_CA} 申请证书..."
        info "使用 HTTP 验证，请确保 TCP 80 端口已放行且未被占用"
        if at_wait_for_acme_cert; then
            info "✅ ACME 证书申请完成，继续输出配置信息"
        else
            warn "⚠ 未在限定时间内找到证书文件（申请可能仍在进行中，sing-box 会自动重试）"
            warn "  可能原因: TCP 80 未开放 / 域名未正确解析 / CA 暂时限流"
            echo -e "  ${CYAN}journalctl -u ${AT_SERVICE_NAME} --no-pager | grep -i acme | tail -20${NC}"
        fi
    fi

    # ── 全部就绪后，统一输出配置信息 ────────────────────────
    at_print_client_info \
        "$TLS_MODE" "$DOMAIN" "$PASSWORD" "$PORT" "${SNI:-$DOMAIN}" \
        "$SERVER_IPV4" "$SERVER_IPV6" "$VERSION" "$AT_CERT_FILE"
}

# ╔══════════════════════════════════════════════════════════╗
# ║        PART 4 — 删除已搭建的节点（卸载并清理干净）        ║
# ╚══════════════════════════════════════════════════════════╝

RE_XRAY_BIN="/usr/local/bin/xray"
RE_XRAY_CONF_DIR="/usr/local/etc/xray"
RE_XRAY_CONF="${RE_XRAY_CONF_DIR}/config.json"
RE_XRAY_SHARE_DIR="/usr/local/share/xray"
RE_XRAY_LOG_DIR="/var/log/xray"
RE_XRAY_SERVICE="$(svc_unit_path xray)"
RE_XRAY_INFO="/root/xray_reality_client.txt"
SYSTEMD_WANTS_DIR="/etc/systemd/system/multi-user.target.wants"

# ────────────────────────────────────────────────────────────
#  是否已搭建（只要程序 / 配置 / 服务文件任意一个还在就算）
# ────────────────────────────────────────────────────────────
re_is_installed() { [[ -e "$RE_XRAY_BIN" || -e "$RE_XRAY_CONF_DIR" || -e "$RE_XRAY_SERVICE" ]]; }
hy2_has_files()   { [[ -e "$HY2_BIN" || -e "$HY2_CONF_DIR" || -e "$HY2_SERVICE" ]]; }
at_has_files()    { [[ -e "$AT_BIN" || -e "$AT_DIR" || -e "$AT_SERVICE" ]]; }

# ────────────────────────────────────────────────────────────
#  读取各节点配置里的监听端口（无 jq 时退回 sed）
# ────────────────────────────────────────────────────────────
re_conf_port() {
    [[ -f "$RE_XRAY_CONF" ]] || return 0
    if command -v jq &>/dev/null; then
        jq -r '.inbounds[0].port // empty' "$RE_XRAY_CONF" 2>/dev/null || true
    else
        sed -nE 's/^[[:space:]]*"port":[[:space:]]*([0-9]+).*$/\1/p' "$RE_XRAY_CONF" | head -1 || true
    fi
    return 0
}

hy2_conf_port() {
    [[ -f "$HY2_CONF" ]] || return 0
    sed -nE 's/^listen:[[:space:]]*:([0-9]+).*$/\1/p' "$HY2_CONF" | head -1 || true
    return 0
}

# ────────────────────────────────────────────────────────────
#  撤销防火墙里放行的 TCP 端口（ufw / firewalld / iptables / ip6tables）
#  只处理确实存在的规则；端口仍被其它程序监听时保留规则
# ────────────────────────────────────────────────────────────
fw_close_tcp_port() {
    local p=$1 n ipt st
    [[ "$p" =~ ^[0-9]+$ ]] || return 0

    if at_port_in_use "$p"; then
        warn "TCP ${p} 端口仍被其它程序占用，保留防火墙放行规则"
        return 0
    fi

    if command -v ufw &>/dev/null; then
        st=$(ufw status 2>/dev/null || true)
        if grep -qE "^${p}/tcp[[:space:]]+ALLOW" <<< "$st"; then
            if ufw --force delete allow "${p}/tcp" >/dev/null 2>&1; then
                info "ufw 已移除 ${p}/tcp 放行规则"
            else
                warn "ufw 移除失败，请手动执行: ufw delete allow ${p}/tcp"
            fi
        fi
    fi

    if command -v firewall-cmd &>/dev/null && firewall-cmd --state &>/dev/null; then
        if firewall-cmd --permanent --query-port="${p}/tcp" &>/dev/null; then
            firewall-cmd --permanent --remove-port="${p}/tcp" >/dev/null 2>&1 || true
            firewall-cmd --reload >/dev/null 2>&1 || true
            info "firewalld 已移除 ${p}/tcp 放行规则"
        fi
    fi

    for ipt in iptables ip6tables; do
        command -v "$ipt" &>/dev/null || continue
        n=0
        while "$ipt" -D INPUT -p tcp --dport "$p" -j ACCEPT 2>/dev/null; do
            n=$(( n + 1 ))
            if (( n >= 20 )); then break; fi
        done
        if (( n > 0 )); then
            info "${ipt} 已移除 ${n} 条 ${p}/tcp 放行规则"
        fi
    done
    return 0
}

# ────────────────────────────────────────────────────────────
#  删除后的残留检查：逐个确认路径已不存在
# ────────────────────────────────────────────────────────────
purge_verify() {
    local label=$1 p
    shift
    local -a left=()
    for p in "$@"; do
        if [[ -e "$p" || -L "$p" ]]; then
            left+=("$p")
        fi
    done
    if (( ${#left[@]} == 0 )); then
        info "✅ ${label}：残留检查通过，已删除干净"
    else
        warn "${label}：以下路径仍然存在，请手动检查："
        for p in "${left[@]}"; do
            echo "      $p"
        done
    fi
    return 0
}

# ────────────────────────────────────────────────────────────
#  三个协议各自的「彻底删除」
# ────────────────────────────────────────────────────────────
re_purge() {
    local port t
    step "删除 VLESS + REALITY（Xray）并清理所有文件"
    port=$(re_conf_port)

    systemctl stop    xray 2>/dev/null || true
    systemctl disable xray 2>/dev/null || true
    pkill -f "^${RE_XRAY_BIN} run" 2>/dev/null || true

    for t in "$RE_XRAY_SERVICE" "${SYSTEMD_WANTS_DIR}/xray.service" "$RE_XRAY_BIN" \
             "$RE_XRAY_CONF_DIR" "$RE_XRAY_SHARE_DIR" "$RE_XRAY_LOG_DIR" "$RE_XRAY_INFO" \
             "$RE_CLASH_FILE"; do
        if [[ -e "$t" || -L "$t" ]]; then
            info "删除 $t"
            rm -rf "$t"
        fi
    done
    svc_remove_unit xray
    rm -f /root/clash_reality_*.yaml "${PAUSED_DIR}"/re-*.json
    systemctl daemon-reload 2>/dev/null || true
    systemctl reset-failed xray 2>/dev/null || true

    if [[ -n "$port" ]]; then
        fw_close_tcp_port "$port"
    fi
    purge_verify "VLESS + REALITY" "$RE_XRAY_SERVICE" "${SYSTEMD_WANTS_DIR}/xray.service" \
        "$RE_XRAY_BIN" "$RE_XRAY_CONF_DIR" "$RE_XRAY_SHARE_DIR" "$RE_XRAY_LOG_DIR" "$RE_XRAY_INFO" \
        "$RE_CLASH_FILE"
    return 0
}

hy2_purge() {
    pkill -f "^${HY2_BIN} server" 2>/dev/null || true
    hy2_do_uninstall        # 内部会读回并清理自定义证书目录、Clash 配置文件
    svc_remove_unit hysteria-server
    systemctl reset-failed hysteria-server 2>/dev/null || true
    purge_verify "Hysteria 2" "$HY2_BIN" "$HY2_SERVICE" "${SYSTEMD_WANTS_DIR}/hysteria-server.service" \
        "$HY2_CONF_DIR" "/var/log/hysteria" "$HY2_CLASH_FILE" \
        "${HY2_CERT_DIR}/server.crt" "${HY2_CERT_DIR}/server.key" "${HY2_ACME_DIR}/certificates"
    return 0
}

at_purge() {
    at_do_uninstall purge   # 内部会读回并清理自定义证书目录、Clash 配置文件
    purge_verify "AnyTLS" "$AT_DIR" "$AT_SERVICE" "$AT_WANTS_LINK" "$AT_CLASH_FILE" \
        "$AT_CERT" "$AT_KEY" "${AT_ACME_DIR}/certificates"
    return 0
}

# ────────────────────────────────────────────────────────────
#  列表里的一行：编号 / 名称 / 端口 / 运行状态
# ────────────────────────────────────────────────────────────
node_row() {
    local idx=$1 label=$2 present=$3 svc=$4 port=$5 st
    if (( present == 1 )); then
        if systemctl is-active --quiet "$svc" 2>/dev/null; then
            st="${GREEN}● 运行中${NC}"
        else
            st="${RED}○ 未运行${NC}"
        fi
        printf "    [%s]  %-28s 端口 %-7s %b\n" "$idx" "$label" "${port:-未知}" "$st"
    else
        printf "    [%s]  %-28s ${DIM}未检测到${NC}\n" "$idx" "$label"
    fi
    return 0
}

# ────────────────────────────────────────────────────────────
#  主菜单「删除已搭建的节点」入口
# ────────────────────────────────────────────────────────────
delete_nodes() {
    clear
    box "删除已搭建的节点"
    echo ""

    local has_re=0 has_hy2=0 has_at=0
    if re_is_installed; then has_re=1; fi
    if hy2_has_files;   then has_hy2=1; fi
    if at_has_files;    then has_at=1; fi

    local re_port hy2_port at_port
    re_port=$(re_conf_port)
    hy2_port=$(hy2_conf_port)
    at_port=$(at_conf_port)

    # 读回各节点实际使用的证书目录（可能是安装时自定义的），用于下面的删除清单
    hy2_load_paths_from_conf
    at_load_paths_from_conf

    echo "  当前检测到的节点："
    echo ""
    node_row 1 "VLESS + REALITY（Xray）" "$has_re"  xray              "$re_port"
    node_row 2 "Hysteria 2"              "$has_hy2" hysteria-server   "$hy2_port"
    node_row 3 "AnyTLS（sing-box）"      "$has_at"  "$AT_SERVICE_NAME" "$at_port"
    echo ""

    if (( has_re + has_hy2 + has_at == 0 )); then
        warn "未检测到本脚本搭建的任何节点，无需删除"
        echo ""
        read -rp "按回车返回主菜单..." _
        return 0
    fi

    local sel tok n todo=" "
    read -rp "  请输入要删除的编号（可多选，如 1 3；a = 全部；0 = 返回）: " sel
    sel=${sel//,/ }
    sel=${sel,,}

    if [[ -z "${sel// /}" || "${sel// /}" == "0" ]]; then
        return 0
    fi

    if [[ "${sel// /}" == "a" || "${sel// /}" == "all" ]]; then
        if (( has_re  == 1 )); then todo+="1 "; fi
        if (( has_hy2 == 1 )); then todo+="2 "; fi
        if (( has_at  == 1 )); then todo+="3 "; fi
    else
        for tok in $sel; do
            case "$tok" in
                1) if (( has_re  == 1 )); then [[ "$todo" == *" 1 "* ]] || todo+="1 "; else warn "未检测到 REALITY 节点，已忽略"; fi ;;
                2) if (( has_hy2 == 1 )); then [[ "$todo" == *" 2 "* ]] || todo+="2 "; else warn "未检测到 Hysteria 2 节点，已忽略"; fi ;;
                3) if (( has_at  == 1 )); then [[ "$todo" == *" 3 "* ]] || todo+="3 "; else warn "未检测到 AnyTLS 节点，已忽略"; fi ;;
                *) warn "无效选项「${tok}」，已忽略" ;;
            esac
        done
    fi

    if [[ -z "${todo// /}" ]]; then
        warn "没有选中任何可删除的节点"
        echo ""
        read -rp "按回车返回主菜单..." _
        return 0
    fi

    # ── 列出将被删除的内容，二次确认 ─────────────────────────
    echo ""
    hr
    echo -e "  ${BOLD}${RED}以下内容将被永久删除：${NC}"
    for n in $todo; do
        case "$n" in
            1)
                echo -e "  ${BOLD}▸ VLESS + REALITY（Xray）${NC}"
                echo "      服务   : xray（停止并禁用）  ${RE_XRAY_SERVICE}"
                echo "      程序   : ${RE_XRAY_BIN}"
                echo "      配置   : ${RE_XRAY_CONF_DIR}（含 UUID / 私钥）"
                echo "      数据   : ${RE_XRAY_SHARE_DIR}    日志: ${RE_XRAY_LOG_DIR}"
                echo "      客户端 : ${RE_XRAY_INFO}    Clash: ${RE_CLASH_FILE}"
                if [[ -n "$re_port" ]]; then
                    echo "      防火墙 : 移除 TCP ${re_port} 放行规则（端口无其它程序占用时）"
                fi
                ;;
            2)
                echo -e "  ${BOLD}▸ Hysteria 2${NC}"
                echo "      服务   : hysteria-server（停止并禁用）  ${HY2_SERVICE}"
                echo "      程序   : ${HY2_BIN}"
                echo "      配置   : ${HY2_CONF_DIR}（含密码 / 自签或 ACME 证书）"
                echo "      日志   : /var/log/hysteria    Clash: ${HY2_CLASH_FILE}"
                if [[ "$HY2_CERT_DIR" != "${HY2_CONF_DIR}"/* && -d "$HY2_CERT_DIR" ]]; then
                    echo "      证书目录: ${HY2_CERT_DIR}（自定义目录：仅删除 server.crt / server.key，目录为空时一并移除）"
                fi
                if [[ "$HY2_ACME_DIR" != "${HY2_CONF_DIR}"/* && -d "$HY2_ACME_DIR" ]]; then
                    echo "      ACME 目录: ${HY2_ACME_DIR}（自定义目录：仅删除 acme / certificates / locks / ocsp 子目录）"
                fi
                ;;
            3)
                echo -e "  ${BOLD}▸ AnyTLS（sing-box）${NC}"
                echo "      服务   : ${AT_SERVICE_NAME}（停止并禁用）  ${AT_SERVICE}"
                echo "      目录   : ${AT_DIR}（sing-box 程序 / 配置 / 证书）    Clash: ${AT_CLASH_FILE}"
                if [[ -d "$AT_ACME_DIR" ]]; then
                    echo "      ACME   : ${AT_ACME_DIR}（证书缓存一并删除，同域名重新搭建需重新签发）"
                fi
                if [[ "$(dirname "$AT_CERT")" != "$AT_DIR" && "$(dirname "$AT_CERT")" != "${AT_DIR}"/* && -f "$AT_CERT" ]]; then
                    echo "      证书目录: $(dirname "$AT_CERT")（自定义目录：仅删除 $(basename "$AT_CERT") / $(basename "$AT_KEY")，目录为空时一并移除）"
                fi
                if [[ -n "$at_port" ]]; then
                    echo "      防火墙 : 移除 TCP ${at_port} 放行规则（端口无其它程序占用时）"
                fi
                ;;
        esac
    done
    echo ""
    echo -e "  ${DIM}不会动：apt/apk 装的 curl/jq 等通用依赖、proxy 快捷命令、80 端口的放行规则${NC}"
    hr
    local ans
    read -rp "  确认删除以上内容？此操作不可恢复 [y/N]: " ans
    if ! [[ "${ans:-N}" =~ ^[Yy]$ ]]; then
        info "已取消，未做任何改动。"
        echo ""
        read -rp "按回车返回主菜单..." _
        return 0
    fi

    # ── 执行删除 ─────────────────────────────────────────────
    for n in $todo; do
        case "$n" in
            1) re_purge  ;;
            2) hy2_purge ;;
            3) at_purge  ;;
        esac
    done

    echo ""
    info "✅ 所选节点已全部删除。客户端里对应的节点配置已失效，请自行移除。"
    echo ""
    read -rp "按回车返回主菜单..." _
    return 0
}


# ╔══════════════════════════════════════════════════════════╗
# ║   PART 5 — 多节点 / 启用·停用协议 / WARP 出口             ║
# ╚══════════════════════════════════════════════════════════╝
#  设计约定：
#   · 每个协议的「第一个节点」= 原有安装流程创建的节点（主节点）
#   · 额外节点：
#       REALITY → Xray config.json 里追加 inbound（同一进程）
#       AnyTLS  → sing-box config.json 里追加 inbound（同一进程）
#       Hy2     → 独立实例：/etc/hysteria/config-N.yaml + hysteria-server-N 服务
#   · 所有对现有配置的修改都是：备份 → 修改 → 校验 → 重启 → 失败自动回滚

pause_any() { local _; read -rp "按回车继续..." _ || true; }

# ────────────────────────────────────────────────────────────
#  端口 / 防火墙
# ────────────────────────────────────────────────────────────
udp_port_in_use() {
    local hex
    local -a files=(/proc/net/udp)
    hex=$(printf '%04X' "$1")
    [[ -r /proc/net/udp6 ]] && files+=(/proc/net/udp6)
    awk -v p=":${hex}\$" 'FNR>1 && $2 ~ p {f=1} END{exit !f}' "${files[@]}" 2>/dev/null
}

# 所有 Hysteria 2 配置文件（主节点 + 额外节点）
hy2_all_confs() {
    local f
    if [[ -f "$HY2_CONF" ]]; then echo "$HY2_CONF"; fi
    for f in "${HY2_CONF_DIR}"/config-*.yaml; do
        if [[ -f "$f" ]]; then echo "$f"; fi
    done
    return 0
}

# 额外 Hysteria 2 节点的配置文件（不含主节点）
hy2_extra_confs() {
    local f
    for f in "${HY2_CONF_DIR}"/config-*.yaml; do
        if [[ -f "$f" ]]; then echo "$f"; fi
    done
    return 0
}

hy2_conf_index() { local n=${1##*/config-}; echo "${n%.yaml}"; }

# 当前配置里（运行中的 inbound）占用的 TCP 端口
active_tcp_ports() {
    command -v jq &>/dev/null || return 0
    if [[ -f "$RE_XRAY_CONF" ]]; then
        jq -r '.inbounds[]? | .port // empty' "$RE_XRAY_CONF" 2>/dev/null || true
    fi
    if [[ -f "$AT_CONF" ]]; then
        jq -r '.inbounds[]? | .listen_port // empty' "$AT_CONF" 2>/dev/null || true
    fi
    return 0
}

# 已在本脚本配置里占用的端口（含已暂停节点，防止恢复时冲突）
# tcp: Xray + AnyTLS；udp: Hysteria 2
configured_ports() {
    local proto=$1 f b
    if [[ "$proto" == "tcp" ]]; then
        active_tcp_ports
        for f in "${PAUSED_DIR:-/etc/proxy-paused}"/re-*.json "${PAUSED_DIR:-/etc/proxy-paused}"/at-*.json; do
            [[ -f "$f" ]] || continue
            b=${f##*/}; b=${b#*-}; echo "${b%.json}"
        done
    else
        for f in $(hy2_all_confs); do
            sed -nE 's/^listen:[[:space:]]*:([0-9]+).*$/\1/p' "$f" | head -1 || true
        done
    fi
    return 0
}

# 询问新节点端口；结果写入 NEW_PORT。参数: tcp|udp 默认端口
NEW_PORT=""
ask_new_port() {
    local proto=$1 def=$2 p ans used
    while true; do
        read -rp "  监听端口（${proto}，默认 ${def}）: " p
        p=${p:-$def}
        if ! [[ "$p" =~ ^[0-9]+$ ]] || (( 10#$p < 1 || 10#$p > 65535 )); then
            warn "端口无效，请输入 1-65535 之间的数字"
            continue
        fi
        p=$(( 10#$p ))
        used=$(configured_ports "$proto")
        if grep -qx "$p" <<< "$used"; then
            warn "${proto} 端口 ${p} 已被本脚本的其它节点占用，请换一个"
            continue
        fi
        if { [[ "$proto" == "tcp" ]] && at_port_in_use "$p"; } \
           || { [[ "$proto" == "udp" ]] && udp_port_in_use "$p"; }; then
            warn "${proto} 端口 ${p} 当前已被其它程序占用"
            read -rp "  仍要使用该端口吗？[y/N]: " ans
            [[ "${ans:-N}" =~ ^[Yy]$ ]] || continue
        fi
        NEW_PORT=$p
        return 0
    done
}

# 放行端口（ufw / firewalld / iptables）。参数: 端口 协议 备注
fw_open_port() {
    local p=$1 proto=${2:-tcp} note=${3:-proxy}
    if command -v ufw &>/dev/null && ufw status 2>/dev/null | grep -q "Status: active"; then
        ufw allow "${p}/${proto}" comment "$note" >/dev/null 2>&1 || true
        info "ufw 已放行 ${p}/${proto}"
    elif command -v firewall-cmd &>/dev/null && firewall-cmd --state &>/dev/null; then
        firewall-cmd --permanent --add-port="${p}/${proto}" >/dev/null 2>&1 || true
        firewall-cmd --reload >/dev/null 2>&1 || true
        info "firewalld 已放行 ${p}/${proto}"
    elif command -v iptables &>/dev/null; then
        iptables -C INPUT -p "$proto" --dport "$p" -j ACCEPT 2>/dev/null \
            || iptables -I INPUT -p "$proto" --dport "$p" -j ACCEPT 2>/dev/null || true
        if command -v ip6tables &>/dev/null; then
            ip6tables -C INPUT -p "$proto" --dport "$p" -j ACCEPT 2>/dev/null \
                || ip6tables -I INPUT -p "$proto" --dport "$p" -j ACCEPT 2>/dev/null || true
        fi
        info "iptables 已放行 ${p}/${proto}（重启后失效，如需持久化请自行保存规则）"
    else
        warn "未检测到防火墙，请确认端口 ${p}/${proto} 可访问"
    fi
    warn "如果云服务商控制台有安全组/防火墙，请同时放行 ${proto^^} ${p}"
    return 0
}

fw_close_udp_port() {
    local p=$1 ipt
    [[ "$p" =~ ^[0-9]+$ ]] || return 0
    if udp_port_in_use "$p"; then return 0; fi
    if command -v ufw &>/dev/null; then
        ufw --force delete allow "${p}/udp" >/dev/null 2>&1 || true
    fi
    if command -v firewall-cmd &>/dev/null && firewall-cmd --state &>/dev/null; then
        firewall-cmd --permanent --remove-port="${p}/udp" >/dev/null 2>&1 || true
        firewall-cmd --reload >/dev/null 2>&1 || true
    fi
    for ipt in iptables ip6tables; do
        command -v "$ipt" &>/dev/null || continue
        "$ipt" -D INPUT -p udp --dport "$p" -j ACCEPT 2>/dev/null || true
    done
    return 0
}

# 协议当前是否处于「被停用」状态（服务既没运行、也没设开机自启）
svc_is_stopped() {
    ! systemctl is-active --quiet "$1" 2>/dev/null && ! systemctl is-enabled --quiet "$1" 2>/dev/null
}

# ════════════════════════════════════════════════════════════
#  5.1  REALITY 多节点
# ════════════════════════════════════════════════════════════
re_show_node() {
    local idx=$1 conf="$RE_XRAY_CONF"
    local port uuid sni sid priv pk="" ipv4 ipv6 host link_v4="" link_v6="" name
    port=$(jq -r ".inbounds[$idx].port // empty" "$conf" 2>/dev/null || true)
    uuid=$(jq -r ".inbounds[$idx].settings.clients[0].id // empty" "$conf" 2>/dev/null || true)
    sni=$(jq -r ".inbounds[$idx].streamSettings.realitySettings.serverNames[0] // empty" "$conf" 2>/dev/null || true)
    sid=$(jq -r ".inbounds[$idx].streamSettings.realitySettings.shortIds[0] // empty" "$conf" 2>/dev/null || true)
    priv=$(jq -r ".inbounds[$idx].streamSettings.realitySettings.privateKey // empty" "$conf" 2>/dev/null || true)
    if [[ -n "$priv" && -x "$RE_XRAY_BIN" ]]; then
        pk=$("$RE_XRAY_BIN" x25519 -i "$priv" 2>/dev/null \
            | awk -F': *' 'tolower($0) ~ /public ?key|password/ {print $NF; exit}' || true)
    fi
    if [[ -z "$port" || -z "$uuid" || -z "$pk" ]]; then
        warn "无法从配置里读取第 $((idx+1)) 个 REALITY 节点的完整信息"
        return 0
    fi

    ipv4=$(hy2_get_ipv4 2>/dev/null || true)
    ipv6=$(hy2_get_ipv6 2>/dev/null || true)
    printf "  ${BOLD}端口${NC}:       %s\n" "$port"
    printf "  ${BOLD}UUID${NC}:        %s\n" "$uuid"
    printf "  ${BOLD}SNI${NC}:         %s\n" "$sni"
    printf "  ${BOLD}ShortId${NC}:     %s\n" "$sid"
    printf "  ${BOLD}公钥 (pbk)${NC}:  %s\n" "$pk"

    if [[ -n "$ipv4" ]]; then
        link_v4="vless://${uuid}@${ipv4}:${port}?encryption=none&flow=xtls-rprx-vision&security=reality&sni=${sni}&fp=chrome&pbk=${pk}&sid=${sid}&type=raw&headerType=none#REALITY-${ipv4}-${port}"
    fi
    if [[ -n "$ipv6" ]]; then
        link_v6="vless://${uuid}@[${ipv6}]:${port}?encryption=none&flow=xtls-rprx-vision&security=reality&sni=${sni}&fp=chrome&pbk=${pk}&sid=${sid}&type=raw&headerType=none#REALITY-v6-${ipv6}-${port}"
    fi
    echo ""
    echo -e "  ${BOLD}${GREEN}VLESS 分享链接:${NC}"
    if [[ -n "$link_v4" ]]; then echo -e "  ${DIM}[IPv4]${NC}"; echo "  ${link_v4}"; fi
    if [[ -n "$link_v6" ]]; then echo -e "  ${DIM}[IPv6]${NC}"; echo "  ${link_v6}"; fi
    if command -v qrencode &>/dev/null; then
        if [[ -n "$link_v4" ]]; then qrencode -t ansiutf8 "$link_v4"; fi
    fi

    host="${ipv4:-$ipv6}"
    if [[ -n "$host" ]]; then
        name="REALITY-${host}-${port}"
        clash_emit "$name" "/root/clash_reality_${port}.yaml" \
            "$(clash_node_reality "$name" "$host" "$port" "$uuid" "$sni" "$pk" "$sid")"
    fi
    return 0
}

re_add_node() {
    step "新增 VLESS + REALITY 节点"
    if [[ ! -f "$RE_XRAY_CONF" || ! -x "$RE_XRAY_BIN" ]]; then
        warn "尚未安装 REALITY，请先在主菜单选择 [1] 安装"
        return 1
    fi
    need_jq || return 1

    local port target_host sni uuid keys priv pub sid tag tmp bak n
    ask_new_port tcp 8443
    port=$NEW_PORT

    echo -e "${YELLOW}提示：target 需支持 TLSv1.3 + H2，且 IP 不在 CDN 上${NC}"
    echo -e "${YELLOW}推荐：dl.google.com | www.microsoft.com | addons.mozilla.org | cdn.jsdelivr.net${NC}"
    read -rp "  伪装目标域名（默认 dl.google.com）: " target_host
    target_host=${target_host:-dl.google.com}
    read -rp "  serverName（默认 ${target_host}）: " sni
    sni=${sni:-$target_host}

    uuid=$("$RE_XRAY_BIN" uuid)
    keys=$("$RE_XRAY_BIN" x25519)
    priv=$(echo "$keys" | grep 'PrivateKey:' | awk '{print $NF}')
    pub=$(echo "$keys" | grep -i 'Password\|PublicKey' | awk '{print $NF}')
    sid=$(openssl rand -hex 8)
    [[ -n "$priv" && -n "$pub" ]] || { warn "密钥生成失败"; return 1; }
    tag="reality-${port}"

    bak="${RE_XRAY_CONF}.addnode.bak"
    cp -a "$RE_XRAY_CONF" "$bak"
    tmp=$(mktemp)
    jq --arg tag "$tag" --argjson port "$port" --arg uuid "$uuid" --arg target "${target_host}:443" \
       --arg sni "$sni" --arg priv "$priv" --arg sid "$sid" '
       .inbounds += [{
         listen: "::", port: $port, protocol: "vless", tag: $tag,
         settings: { clients: [ { id: $uuid, flow: "xtls-rprx-vision" } ], decryption: "none" },
         streamSettings: {
           network: "raw", security: "reality",
           realitySettings: {
             show: false, target: $target, xver: 0, serverNames: [ $sni ],
             privateKey: $priv, maxTimeDiff: 70000, shortIds: [ $sid, "" ]
           }
         },
         sniffing: { enabled: true, destOverride: ["http", "tls", "quic"] }
       }]' "$RE_XRAY_CONF" > "$tmp" || { rm -f "$tmp"; warn "写入配置失败"; return 1; }

    if ! "$RE_XRAY_BIN" run -test -config "$tmp" >/dev/null 2>&1; then
        warn "新配置校验失败，已放弃（原配置未改动）"
        rm -f "$tmp"
        return 1
    fi
    cat "$tmp" > "$RE_XRAY_CONF"
    rm -f "$tmp"

    RE_PORT=$port
    re_configure_firewall

    if svc_is_stopped xray; then
        warn "REALITY 当前处于停用状态：节点已写入配置，启用该协议后生效"
    else
        systemctl restart xray
        sleep 2
        if ! systemctl is-active --quiet xray; then
            warn "Xray 重启失败，正在回滚配置..."
            cp -a "$bak" "$RE_XRAY_CONF"
            systemctl restart xray || true
            return 1
        fi
        info "Xray 已重启，新节点生效 ✔"
    fi

    n=$(jq '.inbounds | length' "$RE_XRAY_CONF")
    box "新节点信息（REALITY #${n}）"
    re_show_node $(( n - 1 ))
    return 0
}

# ════════════════════════════════════════════════════════════
#  5.2  AnyTLS 多节点
# ════════════════════════════════════════════════════════════
at_show_node() {
    local idx=$1 conf="$AT_CONF"
    local port password sni prov domain="" tls_mode cert_file="" ipv4 ipv6 host name
    port=$(jq -r ".inbounds[$idx].listen_port // empty" "$conf" 2>/dev/null || true)
    password=$(jq -r ".inbounds[$idx].users[0].password // empty" "$conf" 2>/dev/null || true)
    sni=$(jq -r ".inbounds[$idx].tls.server_name // empty" "$conf" 2>/dev/null || true)
    prov=$(jq -r ".inbounds[$idx].tls.certificate_provider // empty" "$conf" 2>/dev/null || true)
    at_load_paths_from_conf
    AT_SPKI_B64=""
    AT_FP_COLON=""
    if [[ -n "$prov" ]]; then
        tls_mode=1
        domain=$(jq -r --arg t "$prov" '.certificate_providers[]? | select(.tag == $t) | .domain[0] // empty' "$conf" 2>/dev/null || true)
        cert_file=$(find "$AT_ACME_DIR" -type f -name "${domain:-__none__}.crt" -print -quit 2>/dev/null || true)
    else
        tls_mode=2
        cert_file=$(jq -r ".inbounds[$idx].tls.certificate_path // empty" "$conf" 2>/dev/null || true)
    fi
    if [[ -z "$port" || -z "$password" ]]; then
        warn "无法从配置里读取第 $((idx+1)) 个 AnyTLS 节点的完整信息"
        return 0
    fi

    printf "  ${BOLD}端口${NC}:       %s\n" "$port"
    printf "  ${BOLD}认证密码${NC}:   %s\n" "$password"
    if (( tls_mode == 1 )); then
        printf "  ${BOLD}TLS 模式${NC}:   ACME（域名 %s）\n" "${domain:-未知}"
    else
        printf "  ${BOLD}TLS 模式${NC}:   自签名（SNI %s）\n" "${sni:-未知}"
        [[ -f "$cert_file" ]] && at_print_cert_fingerprint "$cert_file"
    fi

    ipv4=$(hy2_get_ipv4 2>/dev/null || true)
    ipv6=$(hy2_get_ipv6 2>/dev/null || true)
    echo ""
    at_print_links "$tls_mode" "$domain" "$password" "$port" "$sni" "$ipv4" "$ipv6"
    at_print_qr

    if (( tls_mode == 1 )); then host="$domain"; else host="${ipv4:-$ipv6}"; fi
    if [[ -n "$host" ]]; then
        name="AnyTLS-${host}-${port}"
        clash_emit "$name" "/root/clash_anytls_${port}.yaml" \
            "$(clash_node_anytls "$name" "$host" "$port" "$password" "${sni:-$domain}" "$tls_mode" "${AT_FP_COLON:-}")"
    fi
    return 0
}

at_add_node() {
    step "新增 AnyTLS 节点"
    if [[ ! -f "$AT_CONF" || ! -x "$AT_BIN" ]]; then
        warn "尚未安装 AnyTLS，请先在主菜单选择 [3] 安装"
        return 1
    fi
    need_jq || return 1
    at_load_paths_from_conf

    local TLS_MODE DOMAIN="" EMAIL="" ACME_CA="letsencrypt" SNI="" PASSWORD PORT
    local tag prov_tag="" certp="" keyp="" cdir listen sni_val ans ca_choice tmp bak n
    local email_re='^[^@"[:space:]]+@[^@"[:space:]]+\.[^@"[:space:]]+$'

    echo "  TLS 证书模式：  [1] ACME 自动申请（需域名 + TCP 80）   [2] 自签名证书"
    read -rp "  请选择 [1/2]（默认 2）: " TLS_MODE
    TLS_MODE=${TLS_MODE:-2}
    [[ "$TLS_MODE" == "1" || "$TLS_MODE" == "2" ]] || { warn "无效的证书模式"; return 1; }

    if [[ "$TLS_MODE" == "1" ]]; then
        read -rp "  域名（需已解析到本机）: " DOMAIN
        DOMAIN=$(echo "$DOMAIN" | sed -E 's|^https?://||;s|/.*||;s/[[:space:]]//g')
        at_valid_domain "$DOMAIN" || { warn "域名格式不正确"; return 1; }
        read -rp "  邮箱: " EMAIL
        EMAIL=$(echo "$EMAIL" | sed -E 's/[[:space:]]//g')
        [[ "$EMAIL" =~ $email_re ]] || { warn "邮箱格式不正确"; return 1; }
        read -rp "  证书机构 [1] Let's Encrypt（默认） [2] ZeroSSL: " ca_choice
        [[ "${ca_choice:-1}" == "2" ]] && ACME_CA="zerossl" || ACME_CA="letsencrypt"
        warn "ACME 的 HTTP 验证需要占用 TCP 80；若已有其它 ACME 节点正在申请/续期，可能短暂冲突"
        sni_val="$DOMAIN"
    else
        read -rp "  SNI 域名（默认 bing.com）: " SNI
        SNI=${SNI:-bing.com}
        SNI=$(echo "$SNI" | sed -E 's|^https?://||;s|/.*||;s/[[:space:]]//g')
        at_valid_domain "$SNI" || { warn "SNI 必须是合法域名"; return 1; }
        sni_val="$SNI"
    fi

    ask_new_port tcp 8443
    PORT=$NEW_PORT
    PASSWORD=$(head -c 16 /dev/urandom | od -An -tx1 | tr -d ' \n')
    read -rp "  认证密码（默认随机: ${PASSWORD}）: " ans
    PASSWORD=${ans:-$PASSWORD}
    tag="anytls-in-${PORT}"
    listen=$(at_listen_addr)

    if [[ "$TLS_MODE" == "1" ]]; then
        prov_tag="acme-${PORT}"
        cert_dir_prepare "$AT_ACME_DIR"
    else
        cdir=$(dirname "$AT_CERT")
        certp="${cdir}/cert-${PORT}.pem"
        keyp="${cdir}/private-${PORT}.key"
        (
            AT_CERT="$certp"; AT_KEY="$keyp"
            at_gen_selfsigned_cert "$SNI"
        )
    fi

    bak="${AT_CONF}.addnode.bak"
    cp -a "$AT_CONF" "$bak"
    tmp=$(mktemp)
    jq --arg tag "$tag" --argjson port "$PORT" --arg listen "$listen" --arg pw "$PASSWORD" \
       --arg sni "$sni_val" --arg cert "$certp" --arg key "$keyp" --arg prov "$prov_tag" \
       --arg domain "$DOMAIN" --arg adir "$AT_ACME_DIR" --arg email "$EMAIL" --arg ca "$ACME_CA" '
       .inbounds += [{
         type: "anytls", tag: $tag, listen: $listen, listen_port: $port,
         users: [ { name: ("user-" + ($port | tostring)), password: $pw } ],
         tls: ( { enabled: true, server_name: $sni }
                + ( if $prov != "" then { certificate_provider: $prov }
                    else { certificate_path: $cert, key_path: $key } end ) )
       }]
       | if $prov != "" then
           .certificate_providers = ((.certificate_providers // []) +
             [ { type: "acme", tag: $prov, domain: [ $domain ], data_directory: $adir, email: $email, provider: $ca } ])
         else . end' "$AT_CONF" > "$tmp" || { rm -f "$tmp"; warn "写入配置失败"; return 1; }

    if ! "$AT_BIN" check -c "$tmp" >/dev/null 2>&1; then
        warn "新配置校验失败，已放弃（原配置未改动）："
        "$AT_BIN" check -c "$tmp" 2>&1 | tail -5 || true
        rm -f "$tmp"
        return 1
    fi
    cat "$tmp" > "$AT_CONF"
    chmod 600 "$AT_CONF"
    rm -f "$tmp"

    at_configure_firewall "$PORT" "$([[ "$TLS_MODE" == "1" ]] && echo 1 || echo 0)"

    if svc_is_stopped "$AT_SERVICE_NAME"; then
        warn "AnyTLS 当前处于停用状态：节点已写入配置，启用该协议后生效"
    else
        systemctl restart "$AT_SERVICE_NAME"
        sleep 2
        if ! systemctl is-active --quiet "$AT_SERVICE_NAME"; then
            warn "sing-box 重启失败，正在回滚配置..."
            cp -a "$bak" "$AT_CONF"
            systemctl restart "$AT_SERVICE_NAME" || true
            return 1
        fi
        info "sing-box 已重启，新节点生效 ✔"
    fi

    n=$(jq '.inbounds | length' "$AT_CONF")
    box "新节点信息（AnyTLS #${n}）"
    at_show_node $(( n - 1 ))
    return 0
}

# ════════════════════════════════════════════════════════════
#  5.3  Hysteria 2 多节点（每个额外节点 = 独立实例）
# ════════════════════════════════════════════════════════════
hy2_add_node() {
    step "新增 Hysteria 2 节点"
    if [[ ! -x "$HY2_BIN" || ! -f "$HY2_CONF" ]]; then
        warn "尚未安装 Hysteria 2，请先在主菜单选择 [2] 安装"
        return 1
    fi

    local n=2
    while [[ -e "${HY2_CONF_DIR}/config-${n}.yaml" || -e "${HY2_CONF_DIR}/certs-${n}" || -e "${HY2_CONF_DIR}/acme-${n}" ]]; do n=$(( n + 1 )); done

    # 动态作用域：下面这些变量只在本函数及其调用的函数里生效，
    # 复用原有的 hy2_write_config_* / hy2_write_service / hy2_print_client_info
    local HY2_CONF="${HY2_CONF_DIR}/config-${n}.yaml"
    local HY2_CERT_DIR="${HY2_CONF_DIR}/certs-${n}"
    local HY2_ACME_DIR="${HY2_CONF_DIR}/acme-${n}"
    local HY2_CLASH_FILE="/root/clash_hysteria2_${n}.yaml"
    local HY2_SVC_NAME="hysteria-server-${n}"
    local HY2_NODE_TAG="-${n}"

    local TLS_MODE DOMAIN="" EMAIL="" ACME_CA="letsencrypt" SNI="" PORT PASSWORD DEF_PASS ca_choice
    local SERVER_IPV4 SERVER_IPV6 CERT_FILE="" version

    echo "  TLS 证书模式：  [1] ACME 自动申请（需域名 + TCP 80）   [2] 自签名证书"
    read -rp "  请选择 [1/2]（默认 2）: " TLS_MODE
    TLS_MODE=${TLS_MODE:-2}
    SERVER_IPV4=$(hy2_get_ipv4); SERVER_IPV6=$(hy2_get_ipv6)

    if [[ "$TLS_MODE" == "1" ]]; then
        read -rp "  域名（需已解析到本机）: " DOMAIN
        [[ -n "$DOMAIN" ]] || { warn "域名不能为空"; return 1; }
        read -rp "  邮箱: " EMAIL
        [[ -n "$EMAIL" ]] || { warn "邮箱不能为空"; return 1; }
        read -rp "  证书机构 [1] Let's Encrypt（默认） [2] ZeroSSL: " ca_choice
        [[ "${ca_choice:-1}" == "2" ]] && ACME_CA="zerossl" || ACME_CA="letsencrypt"
        warn "ACME 的 HTTP 验证需要占用 TCP 80；若其它节点正在申请/续期证书，可能短暂冲突"
    else
        read -rp "  SNI 域名（默认 bing.com）: " SNI
        SNI=${SNI:-bing.com}
        SNI=$(echo "$SNI" | sed -E 's|^https?://||;s|/.*||;s/[[:space:]]//g')
    fi

    ask_new_port udp 8443
    PORT=$NEW_PORT
    DEF_PASS=$(tr -dc 'A-Za-z0-9!@#^&*' </dev/urandom 2>/dev/null | head -c 20 || openssl rand -base64 16 | tr -d '=+/')
    read -rp "  认证密码（默认随机: ${DEF_PASS}）: " PASSWORD
    PASSWORD=${PASSWORD:-$DEF_PASS}
    hy2_ask_limits

    step "写入服务端配置"
    if [[ "$TLS_MODE" == "1" ]]; then
        hy2_write_config_acme "$DOMAIN" "$EMAIL" "$PASSWORD" "$PORT" "$ACME_CA"
    else
        hy2_gen_selfsigned_cert "$SNI"
        hy2_write_config_selfsigned "$PASSWORD" "$PORT"
    fi
    chmod 600 "$HY2_CONF"
    if warp_state_has hy2; then
        { echo ""; warp_hy2_block; } >> "$HY2_CONF"
        info "已沿用 WARP 出口设置（该节点的出站经 WARP）"
    fi

    hy2_write_service
    systemctl daemon-reload
    fw_open_port "$PORT" udp "Hysteria2-${n}"
    [[ "$TLS_MODE" == "1" ]] && fw_open_port 80 tcp "Hysteria2-ACME"

    if svc_is_stopped hysteria-server; then
        warn "Hysteria 2 当前处于停用状态：节点已写入配置，启用该协议后生效"
    else
        systemctl enable "$HY2_SVC_NAME" >/dev/null 2>&1 || true
        systemctl restart "$HY2_SVC_NAME" || warn "服务启动失败: journalctl -u ${HY2_SVC_NAME} -n 50"
        sleep 2
    fi

    if [[ "$TLS_MODE" == "1" ]]; then
        if hy2_wait_for_acme_cert; then CERT_FILE="$HY2_CERT_FOUND"; fi
    else
        CERT_FILE="${HY2_CERT_DIR}/server.crt"
    fi
    version=$("$HY2_BIN" version 2>/dev/null | awk '/^Version:/{print $2; exit}' || true)
    hy2_print_client_info "$TLS_MODE" "$DOMAIN" "$PASSWORD" "$PORT" "$SNI" \
        "$SERVER_IPV4" "$SERVER_IPV6" "${version:-已安装}" "$CERT_FILE"
    return 0
}

# 额外 Hysteria 2 节点的查看（复用主节点的查看函数）
hy2_show_extra_conf() {
    local f=$1 n
    n=$(hy2_conf_index "$f")
    local HY2_CONF="$f"
    local HY2_CERT_DIR="${HY2_CONF_DIR}/certs-${n}"
    local HY2_ACME_DIR="${HY2_CONF_DIR}/acme-${n}"
    local HY2_CLASH_FILE="/root/clash_hysteria2_${n}.yaml"
    local HY2_SVC_NAME="hysteria-server-${n}"
    local HY2_NODE_TAG="-${n}"
    show_hy2_existing_config || true
    return 0
}

# 「查看配置」里追加：列出所有额外节点
show_extra_nodes_all() {
    local n i f
    if command -v jq &>/dev/null; then
        if [[ -f "$RE_XRAY_CONF" ]]; then
            n=$(jq '.inbounds | length' "$RE_XRAY_CONF" 2>/dev/null || echo 0)
            for (( i = 1; i < n; i++ )); do
                box "REALITY 额外节点 #$(( i + 1 ))"
                re_show_node "$i"
            done
        fi
        if [[ -f "$AT_CONF" ]]; then
            n=$(jq '.inbounds | length' "$AT_CONF" 2>/dev/null || echo 0)
            for (( i = 1; i < n; i++ )); do
                box "AnyTLS 额外节点 #$(( i + 1 ))"
                at_show_node "$i"
            done
        fi
    fi
    for f in $(hy2_extra_confs); do
        hy2_show_extra_conf "$f"
    done
    n=0
    for f in "${PAUSED_DIR}"/re-*.json "${PAUSED_DIR}"/at-*.json; do
        [[ -f "$f" ]] && n=$(( n + 1 ))
    done
    if (( n > 0 )); then
        echo ""
        warn "另有 ${n} 个已暂停的 REALITY/AnyTLS 节点（主菜单 [6] → [4] 可恢复）"
    fi
    return 0
}

# ════════════════════════════════════════════════════════════
#  5.4  单个节点：暂停 / 恢复 / 删除（主节点、额外节点都适用）
#   REALITY / AnyTLS：暂停 = 把该 inbound 从配置里摘出，存到 /etc/proxy-paused/
#   Hysteria 2：暂停 = 停止该实例并取消开机自启
# ════════════════════════════════════════════════════════════
PAUSED_DIR="/etc/proxy-paused"

hy2_svc_of_conf() {
    if [[ "$1" == "$HY2_CONF" ]]; then echo "hysteria-server"; else echo "hysteria-server-$(hy2_conf_index "$1")"; fi
}

# 校验 → 备份 → 写入 → 重启；失败自动回滚。参数: re|at 新配置临时文件
node_conf_apply() {
    local kind=$1 tmp=$2 conf svc bak
    if [[ "$kind" == "re" ]]; then
        conf="$RE_XRAY_CONF"; svc="xray"
        if ! "$RE_XRAY_BIN" run -test -config "$tmp" >/dev/null 2>&1; then
            warn "新配置校验失败，已放弃（原配置未改动）"; rm -f "$tmp"; return 1
        fi
    else
        conf="$AT_CONF"; svc="$AT_SERVICE_NAME"
        if ! "$AT_BIN" check -c "$tmp" >/dev/null 2>&1; then
            warn "新配置校验失败，已放弃（原配置未改动）"; rm -f "$tmp"; return 1
        fi
    fi
    bak="${conf}.node.bak"
    cp -a "$conf" "$bak"
    cat "$tmp" > "$conf"
    rm -f "$tmp"
    if svc_is_stopped "$svc"; then return 0; fi
    systemctl restart "$svc"; sleep 2
    if ! systemctl is-active --quiet "$svc"; then
        warn "${svc} 重启失败，正在回滚配置..."
        cp -a "$bak" "$conf"; systemctl restart "$svc" || true
        return 1
    fi
    return 0
}

# 把第 idx 个 inbound 从配置里摘掉；传入 stash 文件则先存档（暂停用）
inbound_detach() {
    local kind=$1 idx=$2 stash=${3:-} conf tmp
    if [[ "$kind" == "re" ]]; then conf="$RE_XRAY_CONF"; else conf="$AT_CONF"; fi
    if [[ -n "$stash" ]]; then
        mkdir -p "$PAUSED_DIR"; chmod 700 "$PAUSED_DIR"
        jq --argjson i "$idx" '{
              inbound: .inbounds[$i],
              provider: ( (.inbounds[$i].tls.certificate_provider // "") as $t
                          | if $t == "" then null
                            else ((.certificate_providers // []) | map(select(.tag == $t)) | .[0]) end ) }' \
            "$conf" > "$stash" || { rm -f "$stash"; return 1; }
        chmod 600 "$stash"
    fi
    tmp=$(mktemp)
    jq --argjson i "$idx" '
        (.inbounds[$i].tls.certificate_provider // "") as $t
        | del(.inbounds[$i])
        | if $t != "" then .certificate_providers |= map(select(.tag != $t)) else . end' \
        "$conf" > "$tmp" || { rm -f "$tmp"; [[ -n "$stash" ]] && rm -f "$stash"; return 1; }
    if ! node_conf_apply "$kind" "$tmp"; then
        [[ -n "$stash" ]] && rm -f "$stash"
        return 1
    fi
    return 0
}

# 收集全部节点 → NODES 数组，每项: kind|ref|port|state|primary
#   ref：re/at 运行中=inbound 下标，已暂停=暂存文件；hy2=配置文件路径
NODES=()
node_collect() {
    NODES=()
    local n i port f b st
    if command -v jq &>/dev/null; then
        if [[ -f "$RE_XRAY_CONF" ]]; then
            n=$(jq '.inbounds | length' "$RE_XRAY_CONF" 2>/dev/null || echo 0)
            for (( i = 0; i < n; i++ )); do
                port=$(jq -r ".inbounds[$i].port // empty" "$RE_XRAY_CONF")
                NODES+=("re|${i}|${port}|run|$(( i == 0 ? 1 : 0 ))")
            done
        fi
        if [[ -f "$AT_CONF" ]]; then
            n=$(jq '.inbounds | length' "$AT_CONF" 2>/dev/null || echo 0)
            for (( i = 0; i < n; i++ )); do
                port=$(jq -r ".inbounds[$i].listen_port // empty" "$AT_CONF")
                NODES+=("at|${i}|${port}|run|$(( i == 0 ? 1 : 0 ))")
            done
        fi
    fi
    for f in "${PAUSED_DIR}"/re-*.json "${PAUSED_DIR}"/at-*.json; do
        [[ -f "$f" ]] || continue
        b=${f##*/}; port=${b#*-}; port=${port%.json}
        NODES+=("${b%%-*}|${f}|${port}|paused|0")
    done
    for f in $(hy2_all_confs); do
        port=$(sed -nE 's/^listen:[[:space:]]*:([0-9]+).*$/\1/p' "$f" | head -1 || true)
        if systemctl is-active --quiet "$(hy2_svc_of_conf "$f")" 2>/dev/null; then st=run; else st=paused; fi
        NODES+=("hy2|${f}|${port}|${st}|$([[ "$f" == "$HY2_CONF" ]] && echo 1 || echo 0)")
    done
    return 0
}

# 暂停 / 恢复。参数: kind ref port state
node_toggle() {
    local kind=$1 ref=$2 port=$3 state=$4 svc n tmp stash
    case "$kind" in
        hy2)
            svc=$(hy2_svc_of_conf "$ref")
            if [[ "$state" == "run" ]]; then
                systemctl disable --now "$svc" 2>/dev/null || true
                info "已暂停 Hysteria 2 节点（UDP ${port}）"
            else
                systemctl enable --now "$svc" 2>/dev/null || true
                sleep 2
                if systemctl is-active --quiet "$svc"; then info "已恢复 Hysteria 2 节点（UDP ${port}）✔"
                else warn "启动失败: journalctl -u ${svc} -n 30"; fi
            fi
            ;;
        re|at)
            need_jq || return 1
            if [[ "$state" == "run" ]]; then
                if [[ "$kind" == "re" ]]; then n=$(jq '.inbounds | length' "$RE_XRAY_CONF"); else n=$(jq '.inbounds | length' "$AT_CONF"); fi
                if (( n < 2 )); then
                    warn "这是该协议当前唯一在运行的节点，无法单独暂停；要停掉整个协议请用主菜单 [7]"
                    return 1
                fi
                inbound_detach "$kind" "$ref" "${PAUSED_DIR}/${kind}-${port}.json" \
                    && info "已暂停 ${kind^^} 节点（TCP ${port}），配置已存档，可随时恢复" || return 1
            else
                stash="$ref"
                if grep -qx "$port" <<< "$(active_tcp_ports)"; then
                    warn "TCP ${port} 已被其它节点占用，请先处理冲突再恢复"; return 1
                fi
                if at_port_in_use "$port"; then
                    warn "TCP ${port} 当前被其它程序占用，请先释放端口再恢复"; return 1
                fi
                tmp=$(mktemp)
                if [[ "$kind" == "re" ]]; then
                    jq --slurpfile s "$stash" '.inbounds += [ $s[0].inbound ]' "$RE_XRAY_CONF" > "$tmp" || { rm -f "$tmp"; return 1; }
                else
                    jq --slurpfile s "$stash" '
                        .inbounds += [ $s[0].inbound ]
                        | if $s[0].provider != null then
                            .certificate_providers = (((.certificate_providers // []) | map(select(.tag != $s[0].provider.tag))) + [ $s[0].provider ])
                          else . end' "$AT_CONF" > "$tmp" || { rm -f "$tmp"; return 1; }
                fi
                node_conf_apply "$kind" "$tmp" || return 1
                rm -f "$stash"
                info "已恢复 ${kind^^} 节点（TCP ${port}）✔"
            fi
            ;;
    esac
    return 0
}

# 删除单个节点。参数: kind ref port state primary
node_delete() {
    local kind=$1 ref=$2 port=$3 state=$4 primary=$5
    local n np cert="" key="" svc conf e en esvc was=0
    case "$kind" in
        re|at)
            if [[ "$state" == "paused" ]]; then
                rm -f "$ref" "/root/clash_reality_${port}.yaml" "/root/clash_anytls_${port}.yaml"
                info "已删除已暂停的节点"; return 0
            fi
            need_jq || return 1
            if [[ "$kind" == "re" ]]; then n=$(jq '.inbounds | length' "$RE_XRAY_CONF"); else n=$(jq '.inbounds | length' "$AT_CONF"); fi
            if (( n < 2 )); then
                warn "这是该协议唯一在运行的节点；请先恢复其它节点，或用主菜单 [5] 删除整个协议"
                return 1
            fi
            if [[ "$kind" == "at" ]]; then
                cert=$(jq -r ".inbounds[$ref].tls.certificate_path // empty" "$AT_CONF")
                key=$(jq -r ".inbounds[$ref].tls.key_path // empty" "$AT_CONF")
            fi
            inbound_detach "$kind" "$ref" || return 1
            if [[ "$kind" == "re" ]]; then
                rm -f "/root/clash_reality_${port}.yaml"
                if [[ "$primary" == "1" ]]; then
                    rm -f "$RE_CLASH_FILE"
                    np=$(jq -r '.inbounds[0].port // empty' "$RE_XRAY_CONF"); rm -f "/root/clash_reality_${np}.yaml"
                fi
            else
                rm -f "/root/clash_anytls_${port}.yaml"
                if [[ "$primary" == "1" ]]; then
                    rm -f "$AT_CLASH_FILE"
                    np=$(jq -r '.inbounds[0].listen_port // empty' "$AT_CONF"); rm -f "/root/clash_anytls_${np}.yaml"
                fi
                # 证书文件不再被任何节点引用时才删除
                if [[ -n "$cert" ]] && ! grep -qF "\"${cert}\"" "$AT_CONF"; then rm -f "$cert"; fi
                if [[ -n "$key"  ]] && ! grep -qF "\"${key}\""  "$AT_CONF"; then rm -f "$key";  fi
            fi
            fw_close_tcp_port "$port"
            info "✅ 已删除节点（TCP ${port}）"
            ;;
        hy2)
            conf="$ref"
            if [[ "$primary" != "1" ]]; then
                n=$(hy2_conf_index "$conf"); svc="hysteria-server-${n}"
                systemctl stop "$svc" 2>/dev/null || true
                systemctl disable "$svc" 2>/dev/null || true
                svc_remove_unit "$svc"
                systemctl daemon-reload 2>/dev/null || true
                systemctl reset-failed "$svc" 2>/dev/null || true
                rm -rf "$conf" "${HY2_CONF_DIR}/certs-${n}" "${HY2_CONF_DIR}/acme-${n}"
                rm -f "/root/clash_hysteria2_${n}.yaml"
            else
                # 删除第一个节点：把编号最小的额外节点「提升」为主节点
                e=$(hy2_extra_confs | head -1)
                [[ -n "$e" ]] || { warn "没有其它 Hysteria 2 节点，无法单独删除；请用主菜单 [5]"; return 1; }
                en=$(hy2_conf_index "$e"); esvc="hysteria-server-${en}"
                if systemctl is-active --quiet hysteria-server 2>/dev/null || systemctl is-active --quiet "$esvc" 2>/dev/null; then was=1; fi
                systemctl stop hysteria-server 2>/dev/null || true
                systemctl disable --now "$esvc" 2>/dev/null || true
                (
                    HY2_CERT_DIR="${HY2_CERT_DIR:-}"; HY2_ACME_DIR="${HY2_ACME_DIR:-}"
                    hy2_load_paths_from_conf
                    rm -f "${HY2_CERT_DIR}/server.crt" "${HY2_CERT_DIR}/server.key"
                )
                cp -a "$e" "$HY2_CONF"
                svc_remove_unit "$esvc"
                rm -f "$e" "/root/clash_hysteria2_${en}.yaml" "$HY2_CLASH_FILE"
                systemctl daemon-reload 2>/dev/null || true
                systemctl reset-failed "$esvc" 2>/dev/null || true
                if (( was == 1 )); then
                    systemctl enable --now hysteria-server 2>/dev/null || true
                fi
                info "原第一个节点已删除，节点 #${en} 已接替为主节点（证书目录沿用其原有位置）"
            fi
            fw_close_udp_port "$port"
            info "✅ 已删除节点（UDP ${port}）"
            ;;
    esac
    return 0
}

manage_single_node() {
    need_jq || true
    while true; do
        clear
        box "管理单个节点（暂停 / 恢复 / 删除）"
        node_collect
        if (( ${#NODES[@]} == 0 )); then
            warn "没有找到任何节点"; pause_any; return 0
        fi
        echo ""
        local i kind ref port state primary pname stxt c same act sel ans proto
        for i in "${!NODES[@]}"; do
            IFS='|' read -r kind ref port state primary <<< "${NODES[$i]}"
            case "$kind" in re) pname="REALITY";; at) pname="AnyTLS";; hy2) pname="Hysteria 2";; esac
            if [[ "$kind" == "hy2" ]]; then proto="UDP"; else proto="TCP"; fi
            if [[ "$state" == "run" ]]; then stxt="${GREEN}● 运行中${NC}"; else stxt="${YELLOW}○ 已暂停${NC}"; fi
            printf "    [%d]  %-11s %s %-6s %b%s\n" $(( i + 1 )) "$pname" "$proto" "$port" "$stxt" \
                "$([[ "$primary" == "1" ]] && echo '  (第一个节点)')"
        done
        echo ""
        echo -e "  ${DIM}暂停 = 保留配置、停止提供服务，可恢复；删除 = 永久移除${NC}"
        echo -e "  ${DIM}协议只剩一个节点时不能单独暂停/删除（请用主菜单 [7] 停用 或 [5] 删除整个协议）${NC}"
        echo ""
        read -rp "  请输入节点编号（0 = 返回）: " sel
        [[ "$sel" =~ ^[0-9]+$ ]] || return 0
        (( sel == 0 )) && return 0
        (( sel >= 1 && sel <= ${#NODES[@]} )) || { warn "无效编号"; sleep 1; continue; }
        IFS='|' read -r kind ref port state primary <<< "${NODES[$((sel-1))]}"

        same=0
        for c in "${NODES[@]}"; do [[ "${c%%|*}" == "$kind" ]] && same=$(( same + 1 )); done

        if [[ "$state" == "run" ]]; then act="暂停"; else act="恢复"; fi
        read -rp "  [1] ${act}  [2] 删除  [0] 取消: " ans
        case "$ans" in
            1)
                if [[ "$state" == "run" && $same -lt 2 ]]; then
                    warn "该协议只有这一个节点，无法单独暂停；要停整个协议请用主菜单 [7]"
                else
                    node_toggle "$kind" "$ref" "$port" "$state" || true
                fi
                pause_any ;;
            2)
                if (( same < 2 )); then
                    warn "该协议只有这一个节点，无法单独删除；要删除整个协议请用主菜单 [5]"
                else
                    read -rp "  确认永久删除该节点？[y/N]: " c
                    if [[ "${c:-N}" =~ ^[Yy]$ ]]; then node_delete "$kind" "$ref" "$port" "$state" "$primary" || true; fi
                fi
                pause_any ;;
            *) : ;;
        esac
    done
}

# 彻底删除 Hysteria 2 时，先清掉所有额外实例的服务
hy2_purge_extras() {
    local f n st
    for f in $(hy2_extra_confs); do
        n=$(hy2_conf_index "$f")
        st="hysteria-server-${n}"
        systemctl stop "$st" 2>/dev/null || true
        systemctl disable "$st" 2>/dev/null || true
        pkill -f "^${HY2_BIN} server -c ${f}" 2>/dev/null || true
        svc_remove_unit "$st"
        rm -f "/root/clash_hysteria2_${n}.yaml"
        systemctl reset-failed "$st" 2>/dev/null || true
    done
    return 0
}

# ════════════════════════════════════════════════════════════
#  5.5  「新增 / 删除节点」菜单
# ════════════════════════════════════════════════════════════
node_manage_menu() {
    while true; do
        clear
        box "多节点管理（新增节点 / 暂停 / 恢复 / 删除单个节点）"
        echo ""
        echo "    [1]  新增 VLESS + REALITY 节点"
        echo "    [2]  新增 Hysteria 2 节点"
        echo "    [3]  新增 AnyTLS 节点"
        echo "    [4]  管理单个节点（暂停 / 恢复 / 删除）"
        echo "    [0]  返回主菜单"
        echo ""
        local c
        read -rp "  请选择 [0-4]: " c
        case "$c" in
            1) re_add_node  || true; pause_any ;;
            2) hy2_add_node || true; pause_any ;;
            3) at_add_node  || true; pause_any ;;
            4) manage_single_node ;;
            0|"") return 0 ;;
            *) warn "无效选项" ; sleep 1 ;;
        esac
    done
}

# ════════════════════════════════════════════════════════════
#  5.6  启用 / 停用协议
# ════════════════════════════════════════════════════════════
proto_services() {
    local f n
    case "$1" in
        re)  if [[ -e "$RE_XRAY_SERVICE" ]]; then echo xray; fi ;;
        hy2)
            if [[ -e "$HY2_SERVICE" ]]; then echo hysteria-server; fi
            for f in $(hy2_extra_confs); do
                n=$(hy2_conf_index "$f"); echo "hysteria-server-${n}"
            done
            ;;
        at)  if [[ -e "$AT_SERVICE" ]]; then echo "$AT_SERVICE_NAME"; fi ;;
    esac
    return 0
}

# 输出: 运行中 / 已停用 / 异常（已启用但未运行）
proto_state_text() {
    local s act=0 en=0 total=0
    for s in $(proto_services "$1"); do
        total=$(( total + 1 ))
        if systemctl is-active  --quiet "$s" 2>/dev/null; then act=$(( act + 1 )); fi
        if systemctl is-enabled --quiet "$s" 2>/dev/null; then en=$(( en + 1 )); fi
    done
    if (( total == 0 )); then echo "未安装"
    elif (( act == total )); then echo -e "${GREEN}● 运行中${NC}"
    elif (( act == 0 && en == 0 )); then echo -e "${YELLOW}○ 已停用${NC}"
    elif (( act == 0 )); then echo -e "${RED}✗ 已启用但未运行${NC}"
    else echo -e "${YELLOW}◐ 部分运行 (${act}/${total})${NC}"
    fi
}

proto_set_enabled() {   # $1=re|hy2|at  $2=on|off
    local s
    for s in $(proto_services "$1"); do
        if [[ "$2" == "off" ]]; then
            systemctl disable --now "$s" 2>/dev/null || true
            info "已停用 ${s}（停止运行并取消开机自启）"
        else
            systemctl enable --now "$s" 2>/dev/null || true
            sleep 2
            if systemctl is-active --quiet "$s" 2>/dev/null; then
                info "已启用 ${s} ✔"
            else
                warn "${s} 启动失败，最近日志："
                journalctl -u "$s" -n 8 --no-pager 2>/dev/null || true
            fi
        fi
    done
    return 0
}

toggle_protocols() {
    while true; do
        clear
        box "启用 / 停用协议"
        echo ""
        local key
        local i=0
        local -a keys=(re hy2 at)
        local -a labels=("VLESS + REALITY（Xray）" "Hysteria 2" "AnyTLS（sing-box）")
        for key in "${keys[@]}"; do
            printf "    [%d]  %-26s %b\n" $(( i + 1 )) "${labels[$i]}" "$(proto_state_text "$key")"
            i=$(( i + 1 ))
        done
        echo ""
        echo -e "  ${DIM}停用 = 停止服务 + 取消开机自启（配置与节点保留）；启用 = 开机自启 + 立即启动${NC}"
        echo -e "  ${DIM}这里是整个协议一起启停；只想暂停某一个节点请用主菜单 [6] → [4]${NC}"
        echo ""
        local sel act
        read -rp "  请选择协议编号（0 = 返回）: " sel
        case "$sel" in 0|"") return 0 ;; esac
        [[ "$sel" =~ ^[1-3]$ ]] || { warn "无效选项"; sleep 1; continue; }
        key=${keys[$((sel-1))]}
        if [[ -z "$(proto_services "$key")" ]]; then
            warn "${labels[$((sel-1))]} 尚未安装"; sleep 1.5; continue
        fi
        read -rp "  [1] 启用  [2] 停用  [0] 取消: " act
        case "$act" in
            1) proto_set_enabled "$key" on ;;
            2) proto_set_enabled "$key" off ;;
            *) continue ;;
        esac
        pause_any
    done
}

# ════════════════════════════════════════════════════════════
#  5.7  WARP 出口（一键套 WARP）
#   Xray      → wireguard outbound，并设为默认出站
#   sing-box  → wireguard endpoint，并设置 route.final
#   Hysteria2 → 通过本机 wireproxy（SOCKS5 桥）出站：TCP 走 WARP，UDP 仍直连
#  账号：向 Cloudflare 注册免费 WARP 账号（失败时可导入 wgcf-profile.conf）
# ════════════════════════════════════════════════════════════
WARP_DIR="/etc/proxy-warp"
WARP_ACC="${WARP_DIR}/account.json"
WARP_STATE="${WARP_DIR}/enabled"
WARP_BIN="/usr/local/lib/proxy/wireproxy"
WARP_WP_CONF="${WARP_DIR}/wireproxy.conf"
WARP_SVC_NAME="proxy-warp"
WARP_SVC="$(svc_unit_path "$WARP_SVC_NAME")"
WARP_SOCKS_PORT=40000
WARP_MARK_BEGIN="# >>> proxy-warp >>>"
WARP_MARK_END="# <<< proxy-warp <<<"
WARP_EP_HOST=""
WARP_EP_PORT=2408
WARP_PRIV=""
WARP_PUB=""
WARP_TEST_IP=""

warp_state_has()    { [[ -f "$WARP_STATE" ]] && grep -qx "$1" "$WARP_STATE" 2>/dev/null; }
warp_state_add()    { mkdir -p "$WARP_DIR"; warp_state_has "$1" || echo "$1" >> "$WARP_STATE"; }
warp_state_remove() { [[ -f "$WARP_STATE" ]] && sed -i "/^${1}\$/d" "$WARP_STATE"; return 0; }
warp_acc_get()      { jq -r ".$1 // empty" "$WARP_ACC" 2>/dev/null || true; }

# 生成 WireGuard 密钥对（只依赖 openssl）
warp_gen_keys() {
    local pem
    pem=$(openssl genpkey -algorithm X25519 2>/dev/null) || return 1
    WARP_PRIV=$(printf '%s\n' "$pem" | openssl pkey -outform DER 2>/dev/null | tail -c 32 | base64 -w0)
    WARP_PUB=$(printf '%s\n' "$pem" | openssl pkey -pubout -outform DER 2>/dev/null | tail -c 32 | base64 -w0)
    (( ${#WARP_PRIV} == 44 && ${#WARP_PUB} == 44 ))
}

# 保存账号。参数: 私钥 对端公钥 v4 v6 reserved("a,b,c") id token
warp_save_account() {
    mkdir -p "$WARP_DIR"; chmod 700 "$WARP_DIR"
    jq -n --arg priv "$1" --arg ppk "$2" --arg v4 "$3" --arg v6 "$4" --arg rsv "$5" \
          --arg id "${6:-}" --arg token "${7:-}" '
        { private_key: $priv, peer_public_key: $ppk, v4: $v4, v6: $v6,
          reserved: ($rsv | split(",") | map(tonumber)), id: $id, token: $token }' > "$WARP_ACC" \
        || return 1
    chmod 600 "$WARP_ACC"
}

warp_register() {
    need_jq || return 1
    warp_gen_keys || { warn "WireGuard 密钥生成失败（需要 openssl >= 1.1.0）"; return 1; }
    local resp tos id token ppk v4 v6 cid rsv="0,0,0"
    tos=$(date -u +%Y-%m-%dT%H:%M:%S.000Z)
    info "向 Cloudflare 注册 WARP 账号..."
    resp=$(curl -fsS --max-time 20 -X POST "https://api.cloudflareclient.com/v0a2158/reg" \
        -H 'Content-Type: application/json' -H 'User-Agent: okhttp/3.12.1' -H 'CF-Client-Version: a-6.3-1922' \
        -d "{\"key\":\"${WARP_PUB}\",\"install_id\":\"\",\"fcm_token\":\"\",\"tos\":\"${tos}\",\"type\":\"Android\",\"model\":\"PC\",\"locale\":\"en_US\"}" 2>&1) \
        || { warn "注册请求失败: ${resp:0:200}"; return 1; }
    id=$(jq -r '.id // empty' <<< "$resp" 2>/dev/null || true)
    token=$(jq -r '.token // empty' <<< "$resp" 2>/dev/null || true)
    ppk=$(jq -r '.config.peers[0].public_key // empty' <<< "$resp" 2>/dev/null || true)
    v4=$(jq -r '.config.interface.addresses.v4 // empty' <<< "$resp" 2>/dev/null || true)
    v6=$(jq -r '.config.interface.addresses.v6 // empty' <<< "$resp" 2>/dev/null || true)
    cid=$(jq -r '.config.client_id // empty' <<< "$resp" 2>/dev/null || true)
    if [[ -z "$ppk" || -z "$v4" ]]; then
        warn "注册返回内容异常（可能被 Cloudflare 限流/拦截）: ${resp:0:200}"
        return 1
    fi
    if [[ -n "$cid" ]]; then
        rsv=$(printf '%s' "$cid" | base64 -d 2>/dev/null | od -An -tu1 | awk '{printf "%s,%s,%s", $1, $2, $3}' || true)
    fi
    [[ "$rsv" =~ ^[0-9]+,[0-9]+,[0-9]+$ ]] || rsv="0,0,0"
    warp_save_account "$WARP_PRIV" "$ppk" "$v4" "$v6" "$rsv" "$id" "$token" || return 1
    info "✅ WARP 账号已保存到 ${WARP_ACC}"
}

# 从 wgcf-profile.conf / 标准 WireGuard 配置导入
warp_import_profile() {
    need_jq || return 1
    local f=$1 priv pub addrs v4 v6 rsv=""
    [[ -f "$f" ]] || { warn "文件不存在: $f"; return 1; }
    priv=$(sed -nE 's/^[[:space:]]*PrivateKey[[:space:]]*=[[:space:]]*([^[:space:]]+).*/\1/p' "$f" | head -1 || true)
    pub=$(sed -nE 's/^[[:space:]]*PublicKey[[:space:]]*=[[:space:]]*([^[:space:]]+).*/\1/p' "$f" | head -1 || true)
    addrs=$(sed -nE 's/^[[:space:]]*Address[[:space:]]*=[[:space:]]*(.*)$/\1/p' "$f" | tr ',' '\n' | tr -d ' \r' || true)
    v4=$(grep -m1 -E '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+' <<< "$addrs" | sed 's|/.*||' || true)
    v6=$(grep -m1 ':' <<< "$addrs" | sed 's|/.*||' || true)
    [[ -n "$priv" && -n "$pub" && -n "$v4" ]] || { warn "未能从文件解析出 PrivateKey / PublicKey / Address"; return 1; }
    read -rp "  Reserved 三个数字（如 12,34,56；没有就直接回车）: " rsv
    [[ "$rsv" =~ ^[0-9]+,[0-9]+,[0-9]+$ ]] || rsv="0,0,0"
    warp_save_account "$priv" "$pub" "$v4" "$v6" "$rsv" "" "" || return 1
    info "✅ 已导入 WARP 账号"
}

warp_get_account() {
    if warp_register; then return 0; fi
    echo ""
    warn "自动注册失败。可在其它机器/本机用 wgcf 生成 wgcf-profile.conf 后导入。"
    local p
    read -rp "  wgcf-profile.conf 的路径（留空 = 放弃）: " p
    [[ -n "$p" ]] || return 1
    warp_import_profile "$p"
}

# 选择 WARP 端点：有 IPv4 用 IPv4，否则用 IPv6
warp_pick_endpoint() {
    WARP_EP_PORT=2408
    if curl -4 -fsS --max-time 5 -o /dev/null https://www.cloudflare.com/cdn-cgi/trace 2>/dev/null; then
        WARP_EP_HOST="162.159.192.1"
    else
        WARP_EP_HOST="2606:4700:d0::a29f:c001"
    fi
}
warp_ep_str() { if [[ "$WARP_EP_HOST" == *:* ]]; then echo "[${WARP_EP_HOST}]:${WARP_EP_PORT}"; else echo "${WARP_EP_HOST}:${WARP_EP_PORT}"; fi; }

# ── wireproxy（SOCKS5 桥）──────────────────────────────────
warp_install_wireproxy() {
    [[ -x "$WARP_BIN" ]] && return 0
    local arch tmp url bin
    case "$(uname -m)" in
        x86_64)        arch="amd64" ;;
        aarch64|arm64) arch="arm64" ;;
        *) warn "wireproxy 不支持当前架构: $(uname -m)"; return 1 ;;
    esac
    url="https://github.com/pufferffish/wireproxy/releases/latest/download/wireproxy_linux_${arch}.tar.gz"
    info "下载 wireproxy: ${url}"
    tmp=$(mktemp -d)
    if ! curl -fL --retry 3 --max-time 120 -o "${tmp}/w.tgz" "$url"; then
        warn "wireproxy 下载失败"; rm -rf "$tmp"; return 1
    fi
    tar -xzf "${tmp}/w.tgz" -C "$tmp" 2>/dev/null || { warn "wireproxy 解压失败"; rm -rf "$tmp"; return 1; }
    bin=$(find "$tmp" -type f -name wireproxy -print -quit 2>/dev/null || true)
    [[ -n "$bin" ]] || { warn "压缩包里没有 wireproxy"; rm -rf "$tmp"; return 1; }
    install -d -m 755 "$(dirname "$WARP_BIN")"
    install -m 755 "$bin" "$WARP_BIN"
    rm -rf "$tmp"
    info "✅ wireproxy 已安装: ${WARP_BIN}"
}

warp_write_wireproxy_conf() {
    local priv ppk v4 v6 addr
    priv=$(warp_acc_get private_key); ppk=$(warp_acc_get peer_public_key)
    v4=$(warp_acc_get v4); v6=$(warp_acc_get v6)
    addr="${v4}/32"
    if [[ -n "$v6" ]]; then addr="${addr}, ${v6}/128"; fi
    mkdir -p "$WARP_DIR"
    cat > "$WARP_WP_CONF" <<EOF
[Interface]
PrivateKey = ${priv}
Address = ${addr}
DNS = 1.1.1.1
MTU = 1280

[Peer]
PublicKey = ${ppk}
Endpoint = $(warp_ep_str)
AllowedIPs = 0.0.0.0/0, ::/0
PersistentKeepalive = 25

[Socks5]
BindAddress = 127.0.0.1:${WARP_SOCKS_PORT}
EOF
    chmod 600 "$WARP_WP_CONF"
}

warp_bridge_start() {
    if [[ ! -e "$WARP_SVC" ]] && at_port_in_use "$WARP_SOCKS_PORT"; then
        warn "本机 TCP ${WARP_SOCKS_PORT} 已被占用，WARP 桥无法监听"
        return 1
    fi
    svc_write_unit "$WARP_SVC_NAME" "WARP SOCKS5 bridge (wireproxy)" "$WARP_DIR" "$WARP_BIN" \
        "-c ${WARP_WP_CONF}"
    systemctl daemon-reload
    systemctl enable "$WARP_SVC_NAME" >/dev/null 2>&1 || true
    systemctl restart "$WARP_SVC_NAME" || return 1
    local i
    for i in 1 2 3 4 5 6; do
        at_port_in_use "$WARP_SOCKS_PORT" && return 0
        sleep 1
    done
    return 1
}

warp_bridge_stop() {
    systemctl disable --now "$WARP_SVC_NAME" 2>/dev/null || true
    return 0
}

warp_trace() {
    curl -fsS --max-time 15 -x "socks5h://127.0.0.1:${WARP_SOCKS_PORT}" \
        https://www.cloudflare.com/cdn-cgi/trace 2>/dev/null || true
}

# 自检：经 wireproxy 访问 cloudflare trace，确认 warp=on|plus
warp_selftest() {
    warp_install_wireproxy || return 1
    warp_write_wireproxy_conf
    warp_bridge_start || return 1
    local i t
    WARP_TEST_IP=""
    for i in 1 2 3; do
        t=$(warp_trace)
        if grep -qE '^warp=(on|plus)' <<< "$t"; then
            WARP_TEST_IP=$(sed -nE 's/^ip=//p' <<< "$t" | head -1)
            return 0
        fi
        sleep 2
    done
    return 1
}

# ── 各核心的补丁 ───────────────────────────────────────────
warp_wg_json_xray() {
    jq -n --arg sk "$(warp_acc_get private_key)" --arg v4 "$(warp_acc_get v4)" --arg v6 "$(warp_acc_get v6)" \
          --arg pk "$(warp_acc_get peer_public_key)" --arg ep "$(warp_ep_str)" \
          --argjson rsv "$(jq -c '.reserved // [0,0,0]' "$WARP_ACC")" '
        { tag: "warp", protocol: "wireguard",
          settings: {
            secretKey: $sk,
            address: ([ ($v4 + "/32"), (if $v6 != "" then ($v6 + "/128") else empty end) ]),
            peers: [ { publicKey: $pk, allowedIPs: ["0.0.0.0/0", "::/0"], endpoint: $ep } ],
            mtu: 1280, reserved: $rsv } }'
}

warp_wg_json_singbox() {
    jq -n --arg sk "$(warp_acc_get private_key)" --arg v4 "$(warp_acc_get v4)" --arg v6 "$(warp_acc_get v6)" \
          --arg pk "$(warp_acc_get peer_public_key)" --arg host "$WARP_EP_HOST" --argjson port "$WARP_EP_PORT" \
          --argjson rsv "$(jq -c '.reserved // [0,0,0]' "$WARP_ACC")" '
        { type: "wireguard", tag: "warp", mtu: 1280,
          address: ([ ($v4 + "/32"), (if $v6 != "" then ($v6 + "/128") else empty end) ]),
          private_key: $sk,
          peers: [ { address: $host, port: $port, public_key: $pk, allowed_ips: ["0.0.0.0/0", "::/0"], reserved: $rsv } ] }'
}

warp_patch_xray() {   # on|off
    local conf="$RE_XRAY_CONF" bak="${RE_XRAY_CONF}.warp.bak" tmp wg
    [[ -f "$conf" && -x "$RE_XRAY_BIN" ]] || return 0
    tmp=$(mktemp)
    if [[ "$1" == "on" ]]; then
        wg=$(warp_wg_json_xray) || { rm -f "$tmp"; return 1; }
        jq --argjson wg "$wg" '.outbounds = ([ $wg ] + [ (.outbounds // [])[] | select(.tag != "warp") ])' \
            "$conf" > "$tmp" || { rm -f "$tmp"; return 1; }
    else
        jq '.outbounds = [ (.outbounds // [])[] | select(.tag != "warp") ]' "$conf" > "$tmp" \
            || { rm -f "$tmp"; return 1; }
    fi
    if ! "$RE_XRAY_BIN" run -test -config "$tmp" >/dev/null 2>&1; then
        warn "Xray 配置校验失败，未修改"; rm -f "$tmp"; return 1
    fi
    cp -a "$conf" "$bak"
    cat "$tmp" > "$conf"; rm -f "$tmp"
    if svc_is_stopped xray; then return 0; fi
    systemctl restart xray; sleep 2
    if ! systemctl is-active --quiet xray; then
        warn "Xray 重启失败，回滚"; cp -a "$bak" "$conf"; systemctl restart xray || true; return 1
    fi
    return 0
}

warp_patch_singbox() {   # on|off
    local conf="$AT_CONF" bak="${AT_CONF}.warp.bak" tmp ep
    [[ -f "$conf" && -x "$AT_BIN" ]] || return 0
    tmp=$(mktemp)
    if [[ "$1" == "on" ]]; then
        ep=$(warp_wg_json_singbox) || { rm -f "$tmp"; return 1; }
        jq --argjson ep "$ep" '
            .endpoints = ([ (.endpoints // [])[] | select(.tag != "warp") ] + [ $ep ])
            | .route = ((.route // {}) + { final: "warp" })' "$conf" > "$tmp" || { rm -f "$tmp"; return 1; }
    else
        jq '
            .endpoints = [ (.endpoints // [])[] | select(.tag != "warp") ]
            | (if (.endpoints | length) == 0 then del(.endpoints) else . end)
            | (if .route then (.route |= del(.final)) else . end)
            | (if (.route // {}) == {} then del(.route) else . end)' "$conf" > "$tmp" || { rm -f "$tmp"; return 1; }
    fi
    if ! "$AT_BIN" check -c "$tmp" >/dev/null 2>&1; then
        warn "sing-box 配置校验失败，未修改："
        "$AT_BIN" check -c "$tmp" 2>&1 | tail -5 || true
        rm -f "$tmp"; return 1
    fi
    cp -a "$conf" "$bak"
    cat "$tmp" > "$conf"; chmod 600 "$conf"; rm -f "$tmp"
    if svc_is_stopped "$AT_SERVICE_NAME"; then return 0; fi
    systemctl restart "$AT_SERVICE_NAME"; sleep 2
    if ! systemctl is-active --quiet "$AT_SERVICE_NAME"; then
        warn "sing-box 重启失败，回滚"; cp -a "$bak" "$conf"; systemctl restart "$AT_SERVICE_NAME" || true; return 1
    fi
    return 0
}

# Hysteria 2：追加 / 移除 outbounds + acl 段（TCP → WARP，UDP 直连）
warp_hy2_block() {
    cat <<EOF
${WARP_MARK_BEGIN}
outbounds:
  - name: warp
    type: socks5
    socks5:
      addr: 127.0.0.1:${WARP_SOCKS_PORT}
  - name: direct
    type: direct
    direct:
      mode: auto

acl:
  inline:
    - direct(all, udp/*)
    - warp(all)
${WARP_MARK_END}
EOF
}

warp_patch_hy2() {   # on|off
    local f svc bak ok=0 was_active
    for f in $(hy2_all_confs); do
        if [[ "$f" == "$HY2_CONF" ]]; then svc="hysteria-server"; else svc="hysteria-server-$(hy2_conf_index "$f")"; fi
        bak="${f}.warp.bak"
        cp -a "$f" "$bak"
        was_active=0
        if systemctl is-active --quiet "$svc" 2>/dev/null; then was_active=1; fi
        sed -i "\|${WARP_MARK_BEGIN}|,\|${WARP_MARK_END}|d" "$f"
        sed -i -e :a -e '/^\n*$/{$d;N;ba' -e '}' "$f"    # 去掉文件末尾多余空行
        if [[ "$1" == "on" ]]; then
            if grep -qE '^(outbounds|acl):' "$f"; then
                warn "${f} 里已有自定义 outbounds/acl，跳过（请手动处理）"
                cp -a "$bak" "$f"; continue
            fi
            { echo ""; warp_hy2_block; } >> "$f"
        fi
        if (( was_active == 1 )); then
            systemctl restart "$svc"; sleep 2
            if ! systemctl is-active --quiet "$svc"; then
                warn "${svc} 重启失败，回滚"; cp -a "$bak" "$f"; systemctl restart "$svc" || true; ok=1; continue
            fi
        fi
    done
    return $ok
}

warp_enable() {
    need_jq || return 1
    command -v openssl &>/dev/null || { warn "缺少 openssl"; return 1; }
    local any=0 hy2_ok=0
    if [[ ! -f "$RE_XRAY_CONF" && ! -f "$AT_CONF" && ! -f "$HY2_CONF" ]]; then
        warn "未检测到任何已安装的协议，请先安装节点"; return 1
    fi
    if [[ ! -f "$WARP_ACC" ]]; then
        warp_get_account || { warn "没有可用的 WARP 账号，已取消"; return 1; }
    fi
    warp_pick_endpoint
    step "自检：WARP 通道连通性（端点 $(warp_ep_str)）"
    if ! warp_selftest; then
        warn "WARP 通道不通（未能得到 warp=on）。为避免把节点流量引进黑洞，未改动任何节点配置。"
        warn "排查: journalctl -u ${WARP_SVC_NAME} -n 30   / 换账号（菜单 [3]）/ 检查 UDP 2408 是否被封"
        warp_bridge_stop
        return 1
    fi
    info "✅ WARP 通道正常，出口 IP: ${WARP_TEST_IP:-未知}"

    if [[ -f "$RE_XRAY_CONF" ]]; then
        any=1
        step "REALITY（Xray）套 WARP"
        if warp_patch_xray on; then warp_state_add re; info "✔ 完成"; else warn "REALITY 未能套 WARP"; fi
    fi
    if [[ -f "$AT_CONF" ]]; then
        any=1
        step "AnyTLS（sing-box）套 WARP"
        if warp_patch_singbox on; then warp_state_add at; info "✔ 完成"; else warn "AnyTLS 未能套 WARP"; fi
    fi
    if [[ -f "$HY2_CONF" ]]; then
        any=1
        step "Hysteria 2 套 WARP（TCP 经 WARP，UDP 仍直连）"
        if warp_patch_hy2 on; then warp_state_add hy2; hy2_ok=1; info "✔ 完成"; else warn "Hysteria 2 未能套 WARP"; fi
    fi
    if (( hy2_ok == 0 )); then warp_bridge_stop; fi
    (( any == 1 )) || warn "没有可处理的协议"
    echo ""
    info "验证方法：用客户端连上节点后访问 https://www.cloudflare.com/cdn-cgi/trace ，看到 warp=on 即成功"
    return 0
}

warp_disable() {
    need_jq || return 1
    if [[ -f "$RE_XRAY_CONF" ]] && jq -e '.outbounds[]? | select(.tag == "warp")' "$RE_XRAY_CONF" &>/dev/null; then
        warp_patch_xray off && info "REALITY 已恢复直连" || warn "REALITY 恢复失败"
    fi
    if [[ -f "$AT_CONF" ]] && jq -e '.endpoints[]? | select(.tag == "warp")' "$AT_CONF" &>/dev/null; then
        warp_patch_singbox off && info "AnyTLS 已恢复直连" || warn "AnyTLS 恢复失败"
    fi
    local hy2_confs
    hy2_confs=$(hy2_all_confs)
    if [[ -n "$hy2_confs" ]] && grep -qs -- "$WARP_MARK_BEGIN" $hy2_confs; then
        warp_patch_hy2 off && info "Hysteria 2 已恢复直连" || warn "Hysteria 2 恢复失败"
    fi
    rm -f "$WARP_STATE"
    warp_bridge_stop
    info "✅ WARP 出口已关闭（账号保留，可随时重新开启）"
}

warp_purge_all() {
    warp_disable || true
    svc_remove_unit "$WARP_SVC_NAME"
    rm -rf "$WARP_DIR" "$WARP_BIN"
    systemctl daemon-reload 2>/dev/null || true
    info "✅ 已删除 WARP 账号、wireproxy 与相关服务"
}

warp_status() {
    local t ip4
    echo ""
    printf "  %-22s %s\n" "WARP 账号" "$([[ -f "$WARP_ACC" ]] && echo "已注册/导入" || echo "无")"
    printf "  %-22s %s\n" "REALITY 出口"   "$(warp_state_has re  && echo '● 经 WARP' || echo '直连')"
    printf "  %-22s %s\n" "Hysteria 2 出口" "$(warp_state_has hy2 && echo '● 经 WARP（仅 TCP）' || echo '直连')"
    printf "  %-22s %s\n" "AnyTLS 出口"    "$(warp_state_has at  && echo '● 经 WARP' || echo '直连')"
    ip4=$(hy2_get_ipv4 2>/dev/null || true)
    printf "  %-22s %s\n" "本机直连 IPv4" "${ip4:-未知}"
    if systemctl is-active --quiet "$WARP_SVC_NAME" 2>/dev/null; then
        t=$(warp_trace)
        printf "  %-22s %s\n" "WARP 桥出口 IP" "$(sed -nE 's/^ip=//p' <<< "$t" | head -1)  ($(grep -E '^warp=' <<< "$t" | head -1))"
    fi
}

warp_menu() {
    while true; do
        clear
        box "WARP 出口（一键套 WARP）"
        warp_status
        echo ""
        echo "    [1]  一键开启 WARP 出口（所有已安装协议）"
        echo "    [2]  关闭 WARP 出口（恢复直连）"
        echo "    [3]  重新注册 / 导入 WARP 账号"
        echo "    [4]  彻底清理（关闭 + 删除账号与 wireproxy）"
        echo "    [0]  返回主菜单"
        echo ""
        local c
        read -rp "  请选择 [0-4]: " c
        case "$c" in
            1) warp_enable || true; pause_any ;;
            2) warp_disable || true; pause_any ;;
            3) need_jq && { rm -f "$WARP_ACC"; warp_get_account || true; }; pause_any ;;
            4) warp_purge_all || true; pause_any ;;
            0|"") return 0 ;;
            *) warn "无效选项"; sleep 1 ;;
        esac
    done
}

# ════════════════════════════════════════════════════════════
#  入口
# ════════════════════════════════════════════════════════════
show_main_menu
