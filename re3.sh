#!/usr/bin/env bash
# ============================================================
#  Hysteria 2 一键安装脚本（Alpine Linux 版）
#  支持：Hysteria 2（ACME 自动证书 / 自签名证书）
#  支持系统：Alpine Linux 3.x（OpenRC，非 systemd）
#  说明：本脚本从原 Ubuntu/Debian 版移植而来，仅保留
#        Hysteria 2 部分；服务管理由 systemd 改为 OpenRC。
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

# ════════════════════════════════════════════════════════════
#  安装一个稳定命令，方便以后用 hy2 直接启动本脚本
# ════════════════════════════════════════════════════════════
PROXY_COMMAND="/usr/local/bin/hy2"
PROXY_SCRIPT_DIR="/usr/local/lib/proxy"
PROXY_SCRIPT="${PROXY_SCRIPT_DIR}/hy2-alpine.sh"

install_proxy_command() {
    local source_script="${BASH_SOURCE[0]}"
    source_script="$(readlink -f "$source_script" 2>/dev/null || true)"

    if [[ -f "$source_script" && "$source_script" != "$PROXY_SCRIPT" ]]; then
        install -d -m 755 "$PROXY_SCRIPT_DIR"
        install -m 755 "$source_script" "$PROXY_SCRIPT"
    fi

    if [[ ! -f "$PROXY_SCRIPT" ]]; then
        warn "无法安装 hy2 快捷命令：当前脚本不是可读取的文件"
        return 0
    fi

    cat > "$PROXY_COMMAND" <<'PROXY_WRAPPER'
#!/usr/bin/env bash
exec /usr/local/lib/proxy/hy2-alpine.sh "$@"
PROXY_WRAPPER
    chmod 755 "$PROXY_COMMAND"
    info "快捷命令已就绪：现在可以直接输入 hy2 运行此脚本"
}

# ════════════════════════════════════════════════════════════
#  检测系统：必须是 Alpine
# ════════════════════════════════════════════════════════════
hy2_detect_os() {
    if [[ ! -f /etc/alpine-release ]]; then
        error "此脚本仅支持 Alpine Linux（未检测到 /etc/alpine-release）"
    fi
    info "检测到系统：Alpine Linux $(cat /etc/alpine-release)"
}

# ════════════════════════════════════════════════════════════
#  确保运行环境使用 bash（本脚本本身依赖 bash 语法）
#  Alpine 默认 shell 是 busybox ash，需要提前 apk add bash
# ════════════════════════════════════════════════════════════
hy2_ensure_bash() {
    if [[ -z "${BASH_VERSION:-}" ]]; then
        error "请使用 bash 运行本脚本：先执行 apk add --no-cache bash，再用 bash $0 运行"
    fi
}

install_proxy_command
hy2_detect_os
hy2_ensure_bash

# ════════════════════════════════════════════════════════════
#  全局变量
# ════════════════════════════════════════════════════════════
HY2_BIN="/usr/local/bin/hysteria"
HY2_CONF_DIR="/etc/hysteria"
HY2_CONF="${HY2_CONF_DIR}/config.yaml"
HY2_OPENRC_SERVICE="/etc/init.d/hysteria-server"
HY2_CERT_DIR="${HY2_CONF_DIR}/certs"
HY2_ACME_DIR="${HY2_CONF_DIR}/acme"
HY2_LOG_FILE="/var/log/hysteria/hysteria.log"

# 全局：证书指纹（供 URI 使用）
_FP_B64=""
_FP_COLON=""

# ════════════════════════════════════════════════════════════
#  OpenRC 服务管理封装（替代原脚本中的 systemctl / journalctl）
# ════════════════════════════════════════════════════════════
hy2_svc_start()   { rc-service hysteria-server start; }
hy2_svc_stop()    { rc-service hysteria-server stop 2>/dev/null || true; }
hy2_svc_restart() { rc-service hysteria-server restart; }
hy2_svc_enable()  { rc-update add hysteria-server default; }
hy2_svc_disable() { rc-update del hysteria-server default 2>/dev/null || true; }
hy2_svc_is_active() {
    rc-service hysteria-server status 2>/dev/null | grep -qi "started"
}

# ────────────────────────────────────────────────────────────
#  检测是否已安装
# ────────────────────────────────────────────────────────────
hy2_is_installed() {
    [[ -f "$HY2_BIN" ]] || [[ -f "$HY2_OPENRC_SERVICE" ]]
}

# ────────────────────────────────────────────────────────────
#  卸载 & 清理
# ────────────────────────────────────────────────────────────
hy2_do_uninstall() {
    step "卸载现有 Hysteria 2 并清理所有文件"

    hy2_svc_stop
    hy2_svc_disable

    local targets=(
        "$HY2_BIN"
        "$HY2_OPENRC_SERVICE"
        "$HY2_CONF_DIR"
        "/var/log/hysteria"
    )
    for t in "${targets[@]}"; do
        [[ -e "$t" ]] && { info "删除 $t"; rm -rf "$t"; }
    done

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
    ip=$(hostname -I 2>/dev/null | awk '{print $1}') || true
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
#  低内存环境（如小内存的容器/VPS）辅助函数
#  swapon 在部分容器化环境中会因宿主机限制而失败，
#  这里静默尝试，失败就跳过，不影响主流程。
# ────────────────────────────────────────────────────────────
HY2_TMP_SWAP="/swapfile_hy2_tmp"
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
        warn "当前环境不支持创建 swap（常见于容器），改为分批安装以降低内存占用"
    fi
}

hy2_cleanup_swap() {
    [[ -f "$HY2_TMP_SWAP" ]] || return 0
    swapoff "$HY2_TMP_SWAP" &>/dev/null || true
    rm -f "$HY2_TMP_SWAP"
}

# 单个包安装，带重试
hy2_apk_install_one() {
    local pkg="$1" required="${2:-1}" i

    for i in 1 2; do
        if apk add --no-cache "$pkg"; then
            return 0
        fi
        warn "安装 ${pkg} 失败，重试 (${i}/2)..."
        sleep 2
    done

    if [[ "$required" == "1" ]]; then
        return 1
    else
        warn "${pkg} 安装失败，已跳过（非必需，脚本继续）"
        return 0
    fi
}

# ────────────────────────────────────────────────────────────
#  安装系统依赖（Alpine / apk）
#  说明：
#    - curl / openssl / bash：核心依赖
#    - xxd：属于 busybox 内置（Alpine 自带），若缺失回退 python3
#    - gcompat：Hysteria 2 官方发行的二进制基于 glibc 编译，
#      Alpine 是 musl libc，需要 gcompat 提供兼容层才能运行，
#      否则会报 "not found" 或 "Exec format error" 之类的错误
#    - qrencode：生成二维码（非必需）
# ────────────────────────────────────────────────────────────
hy2_install_deps() {
    step "安装依赖（bash curl openssl gcompat）"

    hy2_try_swap

    local i update_ok=0
    for i in 1 2 3; do
        apk update -q && { update_ok=1; break; }
        warn "apk update 失败，重试 (${i}/3)..."
        sleep 2
    done
    (( update_ok == 0 )) && warn "apk update 多次失败，尝试使用现有缓存继续安装"

    local fail=0
    hy2_apk_install_one bash    1 || fail=1
    hy2_apk_install_one curl    1 || fail=1
    hy2_apk_install_one openssl 1 || fail=1
    # gcompat 提供 glibc 兼容层，Hysteria 2 官方二进制需要它才能在
    # musl libc 的 Alpine 上运行；某些极旧/极新架构仓库可能没有此包，
    # 装不上就给出警告，不直接中断（用户可以自行换用其他实现）。
    hy2_apk_install_one gcompat 0 || true
    # qrencode 用于显示二维码，非必需
    hy2_apk_install_one qrencode 0 || true
    # ip6tables 可能不在基础仓库，非必需
    hy2_apk_install_one ip6tables 0 || true

    hy2_cleanup_swap

    if (( fail == 1 )); then
        local missing=()
        command -v curl    &>/dev/null || missing+=("curl")
        command -v openssl &>/dev/null || missing+=("openssl")
        error "依赖安装失败，仍缺少: ${missing[*]}。可尝试手动执行: apk update && apk add --no-cache ${missing[*]}"
    fi

    if ! command -v gcompat &>/dev/null && [[ ! -e /lib/ld-linux-x86-64.so.2 && ! -e /lib64/ld-linux-x86-64.so.2 ]]; then
        warn "未检测到 gcompat glibc 兼容层，Hysteria 2 官方二进制可能无法运行"
        warn "如启动失败并提示 not found / Exec format error，请执行: apk add --no-cache gcompat"
    fi

    info "依赖安装完成"
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
#  写入 OpenRC 服务脚本（替代原来的 systemd unit）
# ────────────────────────────────────────────────────────────
hy2_write_service() {
    mkdir -p "$(dirname "$HY2_LOG_FILE")"
    cat > "$HY2_OPENRC_SERVICE" <<EOF
#!/sbin/openrc-run

name="hysteria-server"
description="Hysteria 2 Server"

command="${HY2_BIN}"
command_args="server -c ${HY2_CONF}"
command_background="yes"
pidfile="/run/\${RC_SVCNAME}.pid"

output_log="${HY2_LOG_FILE}"
error_log="${HY2_LOG_FILE}"

directory="${HY2_CONF_DIR}"

: \${rc_ulimit:="-n 1048576"}

depend() {
    need net
    after firewall
}
EOF
    chmod 755 "$HY2_OPENRC_SERVICE"
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
        echo "（需要 xxd 或 python3，可执行: apk add --no-cache python3）"
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
            warn "未安装 qrencode，无法显示二维码（可运行: apk add --no-cache qrencode）"
        fi
    fi

    # ── 服务管理命令 ────────────────────────────────────────
    box "服务管理（OpenRC）"
    echo ""
    printf "  ${BOLD}%-14s${NC}  ${CYAN}%s${NC}\n" "启动服务"   "rc-service hysteria-server start"
    printf "  ${BOLD}%-14s${NC}  ${CYAN}%s${NC}\n" "停止服务"   "rc-service hysteria-server stop"
    printf "  ${BOLD}%-14s${NC}  ${CYAN}%s${NC}\n" "重启服务"   "rc-service hysteria-server restart"
    printf "  ${BOLD}%-14s${NC}  ${CYAN}%s${NC}\n" "查看状态"   "rc-service hysteria-server status"
    printf "  ${BOLD}%-14s${NC}  ${CYAN}%s${NC}\n" "实时日志"   "tail -f ${HY2_LOG_FILE}"
    printf "  ${BOLD}%-14s${NC}  ${CYAN}%s${NC}\n" "开机自启"   "rc-update add hysteria-server default"
    printf "  ${BOLD}%-14s${NC}  ${CYAN}%s${NC}\n" "编辑配置"   "vi ${HY2_CONF}"
    echo ""
    hr
    if hy2_svc_is_active; then
        echo -e "  服务状态:  ${GREEN}${BOLD}● 运行中 ✅${NC}"
    else
        echo -e "  服务状态:  ${RED}${BOLD}✗ 未运行${NC}"
        warn "服务可能启动失败，查看日志:"
        echo -e "  ${CYAN}tail -n 50 ${HY2_LOG_FILE}${NC}"
    fi
    hr
    echo ""
}

# ────────────────────────────────────────────────────────────
#  查看当前已有配置
# ────────────────────────────────────────────────────────────
show_hy2_existing_config() {
    local config="$HY2_CONF"
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
        cert_file=$(find "${HY2_ACME_DIR:-/etc/hysteria/acme}" -type f -name '*.crt' ! -name '*issuer*' -print -quit 2>/dev/null || true)
    else
        tls_mode="自签名"
        cert_file="${HY2_CERT_DIR:-/etc/hysteria/certs}/server.crt"
    fi

    if [[ -n "$cert_file" && -f "$cert_file" ]]; then
        sni=$(openssl x509 -in "$cert_file" -noout -subject -nameopt RFC2253 2>/dev/null \
            | sed -nE 's/^subject=.*CN=([^,]+).*$/\1/p')
    fi

    if hy2_svc_is_active; then
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
            warn "未安装 qrencode，无法显示二维码（可运行: apk add --no-cache qrencode）"
        fi
    fi

    echo ""
    echo -e "  ${BOLD}原始配置（前 80 行）:${NC}"
    sed -n '1,80p' "$config"
}

show_existing_configs() {
    clear
    box "查看当前已有节点配置"
    if ! show_hy2_existing_config; then
        warn "未找到本脚本创建的 Hysteria 2 配置"
        echo ""
        echo "  Hysteria 2 配置: ${HY2_CONF}"
    fi

    echo ""
    read -rp "按回车返回主菜单..." _
}

# ────────────────────────────────────────────────────────────
#  Hysteria 2 主流程入口
# ────────────────────────────────────────────────────────────
install_hysteria2() {
    clear
    box "Hysteria 2 一键安装脚本（Alpine 版）"
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

    step "配置防火墙"
    if command -v iptables &>/dev/null; then
        iptables -I INPUT -p tcp --dport "${PORT}" -j ACCEPT 2>/dev/null || true
        iptables -I INPUT -p udp --dport "${PORT}" -j ACCEPT 2>/dev/null || true
        info "iptables 已放行端口 ${PORT}/tcp+udp (IPv4)"
        if command -v ip6tables &>/dev/null; then
            ip6tables -I INPUT -p tcp --dport "${PORT}" -j ACCEPT 2>/dev/null || true
            ip6tables -I INPUT -p udp --dport "${PORT}" -j ACCEPT 2>/dev/null || true
            info "ip6tables 已放行端口 ${PORT}/tcp+udp (IPv6)"
        else
            warn "未检测到 ip6tables，若服务器有公网 IPv6，请手动放行 IPv6 的 ${PORT} 端口"
        fi
        warn "注意：iptables 规则未持久化，重启后可能失效。如需保留，请执行:"
        warn "  apk add --no-cache iptables-openrc && rc-update add iptables default && /etc/init.d/iptables save"
    else
        warn "未检测到 iptables，请手动放行端口 ${PORT}（TCP 与 UDP 均需要，Hysteria 2 基于 QUIC/UDP）"
    fi

    step "启动 Hysteria 2 服务"
    hy2_write_service
    hy2_svc_enable
    hy2_svc_restart

    # ── 等待服务完全就绪 ─────────────────────────────────────
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
            warn "  查看日志: tail -f ${HY2_LOG_FILE}"
            CERT_FILE=""
        fi
    else
        # 自签名：等待服务 active（最多 10s）
        local waited=0
        while (( waited < 10 )); do
            hy2_svc_is_active && break
            sleep 1; (( waited++ ))
        done
        if hy2_svc_is_active; then
            info "OpenRC 服务已启动"
        else
            warn "服务启动可能失败，请查看日志: tail -f ${HY2_LOG_FILE}"
        fi
        CERT_FILE="${HY2_CERT_DIR}/server.crt"
    fi

    # ── 全部就绪后，统一输出配置信息 ────────────────────────
    hy2_print_client_info \
        "$TLS_MODE" "$DOMAIN" "$PASSWORD" "$PORT" "$SNI" \
        "$SERVER_IPV4" "$SERVER_IPV6" "$VERSION" "$CERT_FILE"

    echo ""
    info "✅ Hysteria 2 安装完成！请将上方配置信息导入客户端。"
    echo ""
}

# ════════════════════════════════════════════════════════════
#  主菜单
# ════════════════════════════════════════════════════════════
show_main_menu() {
    while true; do
    clear
    echo -e "${BOLD}${CYAN}"
    echo "  ╔══════════════════════════════════════════════════════╗"
    echo "  ║       Hysteria 2 一键安装脚本（Alpine 版）           ║"
    echo "  ╚══════════════════════════════════════════════════════╝"
    echo -e "${NC}"
    echo "    [1]  安装 Hysteria 2"
    echo ""
    echo "    [2]  查看当前已有节点配置"
    echo ""
    echo "    [0]  退出"
    echo ""
    read -rp "  请输入 [0/1/2]（默认 1）: " CHOICE
    CHOICE=${CHOICE:-1}
    case "$CHOICE" in
        1) install_hysteria2; return ;;
        2) show_existing_configs ;;
        0) echo ""; info "已退出。"; exit 0 ;;
        *) warn "无效选项，请重新运行脚本"; exit 1 ;;
    esac
    done
}

# ════════════════════════════════════════════════════════════
#  入口
# ════════════════════════════════════════════════════════════
show_main_menu
