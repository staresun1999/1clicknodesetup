#!/usr/bin/env bash
# =====================================================================
# xnode — VMess+WS / VLESS+XHTTP 节点管理脚本（Xray-core + Caddy）
# 适用：Ubuntu / Debian（需 root、systemd、交互式终端）
#
# 运行：bash xnode.sh        首次运行会把自己安装为命令 xnode，之后直接输入 xnode 即可
#
# 功能：新增节点（VMess+WS / VLESS+XHTTP）、查看并输出 Clash Mihomo 节点配置、
#       修改节点、暂停/恢复节点、删除节点、卸载（按协议卸载 / 完全卸载）
# 说明：所有配置均由用户在提示中手动输入，回车使用 [默认值]。
# =====================================================================
set -u
set -o pipefail

STATE_DIR=/usr/local/etc/xnode
NODES_FILE=$STATE_DIR/nodes.json
META_FILE=$STATE_DIR/meta
SELF_BIN=/usr/local/bin/xnode
XRAY_BIN=/usr/local/bin/xray
XRAY_CONF=/usr/local/etc/xray/config.json
XRAY_CONF_TMP=/usr/local/etc/xray/config.new.json
CADDYFILE=/etc/caddy/Caddyfile
MARK="# managed by xnode"
CF_PORTS="443、2053、2083、2087、2096、8443"

SERVER_IP=""
SEL=-1
NEW_NODE=""

# ------------------------- 基础工具 -------------------------
info() { echo -e "\033[32m[INFO]\033[0m $*"; }
warn() { echo -e "\033[33m[WARN]\033[0m $*"; }
die()  { echo -e "\033[31m[ERROR]\033[0m $*" >&2; exit 1; }

# ask "提示语" -> 输出用户输入（去除首尾空白），读写均走 /dev/tty
ask() {
  local ans=""
  { printf '%s' "$1" > /dev/tty; } 2>/dev/null || true
  IFS= read -r ans 2>/dev/null < /dev/tty || ans=""
  ans="${ans#"${ans%%[![:space:]]*}"}"
  ans="${ans%"${ans##*[![:space:]]}"}"
  printf '%s' "$ans"
}

# yn y|n "提示"  —— 第一个参数为回车时的默认答案
yn() {
  local ans
  ans=$(ask "$2")
  case "$ans" in
    [Yy]*) return 0 ;;
    [Nn]*) return 1 ;;
    "")    [[ "$1" == y ]] ;;
    *)     return 1 ;;
  esac
}

pause_enter() { ask "按回车返回菜单..." > /dev/null; }

port_in_use() { ss -ltn "( sport = :$1 )" 2>/dev/null | grep -q LISTEN; }

get_ip() {
  local u ip=""
  for u in https://api.ipify.org https://icanhazip.com https://ifconfig.me; do
    ip=$(curl -4 -fsS --max-time 5 "$u" 2>/dev/null | tr -d '[:space:]') || ip=""
    [[ -n "$ip" ]] && { echo "$ip"; return; }
  done
}

pub_ip() {
  [[ -n "$SERVER_IP" ]] || SERVER_IP=$(get_ip)
  echo "${SERVER_IP:-YOUR_SERVER_IP}"
}

gen_uuid() { cat /proc/sys/kernel/random/uuid; }
gen_path() { echo "/$(cut -d- -f1 /proc/sys/kernel/random/uuid)"; }

valid_domain() { [[ "$1" =~ ^([A-Za-z0-9]([A-Za-z0-9-]*[A-Za-z0-9])?\.)+[A-Za-z]{2,}$ ]]; }
valid_uuid()   { [[ "$1" =~ ^[0-9a-fA-F]{8}-([0-9a-fA-F]{4}-){3}[0-9a-fA-F]{12}$ ]]; }
valid_path()   { [[ "$1" =~ ^/[A-Za-z0-9_.-]+(/[A-Za-z0-9_.-]+)*$ ]]; }
valid_port()   { [[ "$1" =~ ^[0-9]+$ ]] && (( 10#$1 >= 1 && 10#$1 <= 65535 )); }
cf_port()      { case "$1" in 443|2053|2083|2087|2096|8443) return 0 ;; *) return 1 ;; esac; }

# ------------------------- 状态文件 -------------------------
meta_get() { grep -s "^$1=" "$META_FILE" | head -n1 | cut -d= -f2-; }
meta_set() { sed -i "/^$1=/d" "$META_FILE" 2>/dev/null; echo "$1=$2" >> "$META_FILE"; }

init_state() {
  mkdir -p "$STATE_DIR"
  [[ -f "$NODES_FILE" ]] || echo '[]' > "$NODES_FILE"
  if [[ ! -f "$META_FILE" ]]; then
    : > "$META_FILE"
    if [[ -x "$XRAY_BIN" ]]; then meta_set XRAY_PREEXIST 1; else meta_set XRAY_PREEXIST 0; fi
    if command -v caddy >/dev/null; then meta_set CADDY_PREEXIST 1; else meta_set CADDY_PREEXIST 0; fi
  fi
}

node_count() { jq 'length' "$NODES_FILE"; }
nf()         { jq -r --argjson i "$1" --arg f "$2" '.[$i][$f]' "$NODES_FILE"; }

ensure_deps() {
  local c need=0
  for c in curl jq ss unzip shuf; do command -v "$c" >/dev/null || need=1; done
  (( need )) || return 0
  info "安装依赖..."
  export DEBIAN_FRONTEND=noninteractive
  apt-get update -y >/dev/null 2>&1
  apt-get install -y curl ca-certificates jq iproute2 unzip coreutils >/dev/null 2>&1 \
    || die "依赖安装失败，请检查 apt 源"
  for c in curl jq ss unzip shuf; do command -v "$c" >/dev/null || die "缺少依赖：$c"; done
}

install_self() {
  local me
  me=$(readlink -f "$0" 2>/dev/null) || return 0
  [[ -f "$me" && "$me" != "$SELF_BIN" ]] || return 0
  cp -f "$me" "$SELF_BIN" 2>/dev/null && chmod +x "$SELF_BIN" \
    && info "已安装管理命令：xnode（以后直接输入 xnode 即可进入菜单）"
}

# ------------------------- 端口分配与校验 -------------------------
rand_port() {
  local p
  while :; do
    p=$(shuf -i 10000-60000 -n 1)
    port_in_use "$p" && continue
    jq -e --argjson p "$p" 'any(.[]; .port == $p or .xport == $p)' "$NODES_FILE" >/dev/null && continue
    echo "$p"; return
  done
}

# check_port 端口 域名(可空) 自身编号(-1=新建)；冲突时输出原因并返回 1
check_port() {
  local p=$1 dm=$2 self=$3 q
  if [[ -n "$dm" ]]; then
    # 域名节点（Caddy）：可与其他域名节点共用端口，但不能与直连节点/内部端口冲突
    q='to_entries | map(select(.key != $s and ((.value.domain == "" and .value.port == $p) or .value.xport == $p))) | length'
  else
    q='to_entries | map(select(.key != $s and (.value.port == $p or .value.xport == $p))) | length'
  fi
  if (( $(jq --argjson p "$p" --argjson s "$self" "$q" "$NODES_FILE") > 0 )); then
    echo "端口 $p 已被其他节点占用"; return 1
  fi
  if port_in_use "$p"; then
    if ! jq -e --argjson p "$p" 'any(.[]; .port == $p)' "$NODES_FILE" >/dev/null; then
      echo "端口 $p 已被系统中其他程序占用"; return 1
    fi
  fi
  return 0
}

# 同一 域名+端口 下路径不能重复
path_taken() {
  jq -e --arg d "$1" --argjson p "$2" --arg pa "$3" --argjson s "$4" \
    'to_entries | map(select(.key != $s and .value.domain == $d and .value.port == $p and .value.path == $pa)) | length > 0' \
    "$NODES_FILE" >/dev/null
}

name_taken() {
  jq -e --arg n "$1" --argjson s "$2" \
    'to_entries | map(select(.key != $s and .value.name == $n)) | length > 0' "$NODES_FILE" >/dev/null
}

# ------------------------- 防火墙 -------------------------
ufw_active() { command -v ufw >/dev/null && ufw status 2>/dev/null | grep -q "Status: active"; }
fw_open()    { ufw_active && ufw allow "$1/tcp" >/dev/null 2>&1; return 0; }
fw_release() {
  jq -e --argjson p "$1" 'any(.[]; .port == $p)' "$NODES_FILE" >/dev/null && return 0
  ufw_active && ufw delete allow "$1/tcp" >/dev/null 2>&1
  return 0
}

# ------------------------- 安装 Xray / Caddy -------------------------
ensure_xray() {
  [[ -x "$XRAY_BIN" ]] && return 0
  local log=/tmp/xnode-xray-install.log
  info "安装 Xray-core（安装日志：$log）..."
  curl -fsSL -o /tmp/xray-install.sh \
    https://github.com/XTLS/Xray-install/raw/main/install-release.sh \
    || { warn "下载 Xray 安装脚本失败，请检查 VPS 到 GitHub 的连通性"; return 1; }
  bash /tmp/xray-install.sh install 2>&1 | tee "$log"
  rm -f /tmp/xray-install.sh
  if [[ ! -x "$XRAY_BIN" ]]; then
    warn "Xray 安装失败，上面是安装程序的原始输出（完整日志：$log）"
    return 1
  fi
}

ensure_caddy() {
  command -v caddy >/dev/null && return 0
  info "安装 Caddy..."
  export DEBIAN_FRONTEND=noninteractive
  apt-get install -y debian-keyring debian-archive-keyring apt-transport-https gnupg >/dev/null 2>&1
  curl -fsSL 'https://dl.cloudsmith.io/public/caddy/stable/gpg.key' \
    | gpg --dearmor --yes -o /usr/share/keyrings/caddy-stable-archive-keyring.gpg \
    || { warn "获取 Caddy 签名密钥失败"; return 1; }
  curl -fsSL 'https://dl.cloudsmith.io/public/caddy/stable/debian.deb.txt' \
    > /etc/apt/sources.list.d/caddy-stable.list || { warn "获取 Caddy 软件源失败"; return 1; }
  apt-get update -y >/dev/null 2>&1
  apt-get install -y caddy >/dev/null 2>&1
  command -v caddy >/dev/null || { warn "Caddy 安装失败"; return 1; }
}

# 若系统里原本就有 Xray 配置，首次接管前备份并征得同意
claim_xray_conf() {
  [[ -f "$STATE_DIR/xray_owned" ]] && return 0
  if [[ "$(meta_get XRAY_PREEXIST)" == 1 && -f "$XRAY_CONF" ]]; then
    warn "检测到系统中已有 Xray 配置：$XRAY_CONF"
    yn n "继续将备份原配置并由本脚本接管（卸载时会还原），确认？[y/N]: " || return 1
    cp -f "$XRAY_CONF" "$XRAY_CONF.xnode.bak"
  fi
  touch "$STATE_DIR/xray_owned"
}

# ------------------------- 配置生成 -------------------------
gen_xray_conf() {
  jq '{
    log: {loglevel: "warning"},
    inbounds: [ .[] | select(.enabled) | {
      tag: ("in-" + (.xport | tostring)),
      listen: (if .domain == "" then "0.0.0.0" else "127.0.0.1" end),
      port: .xport,
      protocol: .proto,
      settings: (if .proto == "vmess"
                 then {clients: [{id: .uuid, alterId: 0}]}
                 else {clients: [{id: .uuid}], decryption: "none"} end),
      streamSettings: (if .net == "ws"
                       then {network: "ws", wsSettings: {path: .path}}
                       else {network: "xhttp", xhttpSettings: {path: .path}} end)
    } ],
    outbounds: [ {protocol: "freedom"} ]
  }' "$NODES_FILE"
}

gen_caddyfile() {
  echo "$MARK"
  jq -r '
    [ .[] | select(.enabled and .domain != "") ]
    | group_by(.domain + ":" + (.port | tostring))
    | .[]
    | ( "\(.[0].domain):\(.[0].port) {",
        ( .[] | (
            "\thandle \(if .net == "xhttp" then .path + "/*" else .path end) {",
            "\t\treverse_proxy \(if .net == "xhttp" and .mode == "stream-up" then "h2c://" else "" end)127.0.0.1:\(.xport)\(if .net == "xhttp" then " {" else "" end)",
            ( if .net == "xhttp" then ("\t\t\tflush_interval -1", "\t\t}") else empty end ),
            "\t}" ) ),
        "\thandle {",
        "\t\trespond \"Not Found\" 404",
        "\t}",
        "}" )
  ' "$NODES_FILE"
}

# 根据 nodes.json 重新生成并应用 Xray / Caddy 配置（暂停的节点不会写入配置）
apply() {
  local en dn
  en=$(jq '[.[] | select(.enabled)] | length' "$NODES_FILE")
  dn=$(jq '[.[] | select(.enabled and .domain != "")] | length' "$NODES_FILE")

  if (( en > 0 )); then
    ensure_xray || return 1
    claim_xray_conf || return 1
    mkdir -p "$(dirname "$XRAY_CONF")"
    gen_xray_conf > "$XRAY_CONF_TMP" || { rm -f "$XRAY_CONF_TMP"; return 1; }
    chmod 644 "$XRAY_CONF_TMP"
    if ! "$XRAY_BIN" run -test -config "$XRAY_CONF_TMP" >/dev/null 2>&1; then
      warn "Xray 配置校验失败"; rm -f "$XRAY_CONF_TMP"; return 1
    fi
    mv -f "$XRAY_CONF_TMP" "$XRAY_CONF"
    systemctl enable xray >/dev/null 2>&1
    systemctl restart xray; sleep 1
    systemctl is-active --quiet xray || { warn "Xray 启动失败，请查看：journalctl -u xray -n 50"; return 1; }
  elif [[ -x "$XRAY_BIN" && -f "$STATE_DIR/xray_owned" ]]; then
    systemctl stop xray >/dev/null 2>&1
    systemctl disable xray >/dev/null 2>&1
  fi

  if (( dn > 0 )); then
    ensure_caddy || return 1
    if ! systemctl is-active --quiet caddy && port_in_use 80; then
      warn "80 端口被占用，Caddy 申请证书需要 80 端口"; return 1
    fi
    mkdir -p /etc/caddy
    gen_caddyfile > "$CADDYFILE.new" || { rm -f "$CADDYFILE.new"; return 1; }
    if ! caddy validate --config "$CADDYFILE.new" --adapter caddyfile >/dev/null 2>&1; then
      warn "Caddy 配置校验失败"; rm -f "$CADDYFILE.new"; return 1
    fi
    if [[ -f "$CADDYFILE" ]] && ! grep -qF "$MARK" "$CADDYFILE" && [[ ! -f "$CADDYFILE.xnode.bak" ]]; then
      cp -f "$CADDYFILE" "$CADDYFILE.xnode.bak"
    fi
    mv -f "$CADDYFILE.new" "$CADDYFILE"
    systemctl enable caddy >/dev/null 2>&1
    systemctl restart caddy; sleep 2
    systemctl is-active --quiet caddy || { warn "Caddy 启动失败，请查看：journalctl -u caddy -n 50"; return 1; }
  elif [[ -f "$CADDYFILE" ]] && grep -qF "$MARK" "$CADDYFILE"; then
    systemctl stop caddy >/dev/null 2>&1
    systemctl disable caddy >/dev/null 2>&1
  fi
  return 0
}

# 写入新的节点列表并应用；失败则回滚
commit_nodes() {
  local old
  old=$(cat "$NODES_FILE")
  echo "$1" > "$NODES_FILE"
  if ! apply; then
    warn "应用失败，已回滚到修改前的状态"
    echo "$old" > "$NODES_FILE"
    apply >/dev/null 2>&1
    return 1
  fi
  return 0
}

# ------------------------- 显示 -------------------------
list_nodes() {
  if (( $(node_count) == 0 )); then echo "  （暂无节点）"; return; fi
  jq -r 'to_entries[] | "  \(.key + 1)) [\(if .value.enabled then "运行" else "暂停" end)] \(.value.name)  \(.value.proto)+\(.value.net)  \(if .value.domain == "" then "IP" else .value.domain end):\(.value.port)  \(.value.path)"' "$NODES_FILE"
}

show_summary() {
  jq -r '
    "协议      : \(.proto) + \(.net)\(if .mode != "" then " (" + .mode + ")" else "" end)",
    "域名/TLS  : \(if .domain == "" then "无（直连 IP，无 TLS）" else .domain + "（Caddy 自动 TLS）" end)",
    "端口      : \(.port)",
    "UUID      : \(.uuid)",
    "路径      : \(.path)",
    "名称      : \(.name)"' <<< "$NEW_NODE"
}

# 输出某个节点的 Clash Mihomo 配置（仅节点部分）
clash_of() {
  local i=$1 name proto net mode domain port uuid path server
  name=$(nf "$i" name);     proto=$(nf "$i" proto); net=$(nf "$i" net)
  mode=$(nf "$i" mode);     domain=$(nf "$i" domain); port=$(nf "$i" port)
  uuid=$(nf "$i" uuid);     path=$(nf "$i" path)
  if [[ -n "$domain" ]]; then server=$domain; else server=$(pub_ip); fi

  echo "proxies:"
  echo "  - name: \"$name\""
  echo "    type: $proto"
  echo "    server: $server"
  echo "    port: $port"
  echo "    uuid: $uuid"
  if [[ "$proto" == vmess ]]; then
    echo "    alterId: 0"
    echo "    cipher: auto"
  fi
  echo "    udp: true"
  if [[ -n "$domain" ]]; then
    echo "    tls: true"
    echo "    servername: $domain"
    [[ "$proto" == vless ]] && echo "    client-fingerprint: chrome"
    echo "    skip-cert-verify: false"
  fi
  if [[ "$net" == ws ]]; then
    echo "    network: ws"
    echo "    ws-opts:"
    echo "      path: $path"
    if [[ -n "$domain" ]]; then
      echo "      headers:"
      echo "        Host: $domain"
    fi
  else
    echo "    network: xhttp"
    echo "    xhttp-opts:"
    echo "      path: $path"
    echo "      host: $domain"
    echo "      mode: $mode"
  fi
}

print_clash() {
  echo "------------------------------------------------------------"
  clash_of "$1"
  echo "------------------------------------------------------------"
  if [[ -n "$(nf "$1" domain)" ]]; then
    echo "走 Cloudflare CDN：域名需开启橙云，SSL/TLS 模式选 Full 或 Full (strict)；"
    echo "使用优选 IP：只把 server 改成优选 IP，servername / Host / host 保持为域名。"
  else
    echo "提示：请确认云服务商安全组已放行 TCP $(nf "$1" port)"
  fi
}

choose_node() {
  local n ans
  n=$(node_count)
  if (( n == 0 )); then warn "当前没有节点"; return 1; fi
  list_nodes
  while :; do
    ans=$(ask "$1（回车取消）: ")
    [[ -z "$ans" ]] && return 1
    if [[ "$ans" =~ ^[0-9]+$ ]] && (( 10#$ans >= 1 && 10#$ans <= n )); then
      SEL=$(( 10#$ans - 1 )); return 0
    fi
    warn "编号无效"
  done
}

# ------------------------- 交互式输入 -------------------------
# prompt_node 协议 传输 自身编号(-1=新建) —— 结果写入全局 NEW_NODE
prompt_node() {
  local proto=$1 net=$2 self=$3
  local d_name d_domain d_port d_uuid d_path d_mode d_xport d_en ans msg n
  local name domain port uuid path mode xport

  if (( self >= 0 )); then
    d_name=$(nf "$self" name);   d_domain=$(nf "$self" domain)
    d_port=$(nf "$self" port);   d_uuid=$(nf "$self" uuid)
    d_path=$(nf "$self" path);   d_mode=$(nf "$self" mode)
    d_xport=$(nf "$self" xport); d_en=$(nf "$self" enabled)
  else
    n=$(( $(node_count) + 1 ))
    d_name="${proto}-${net}-${n}"
    while name_taken "$d_name" -1; do n=$((n + 1)); d_name="${proto}-${net}-${n}"; done
    d_domain=""; d_port=""; d_uuid=$(gen_uuid); d_path=$(gen_path)
    d_mode="packet-up"; d_xport=""; d_en=true
  fi
  [[ -z "$d_mode" || "$d_mode" == null ]] && d_mode="packet-up"

  echo
  (( self >= 0 )) && info "修改节点：直接回车保留原值" || info "新增节点：直接回车使用 [默认值]"

  # 1) 域名
  while :; do
    if [[ "$net" == xhttp ]]; then
      ans=$(ask "1) 域名（必填，需已解析到本机或 Cloudflare）${d_domain:+ [$d_domain]}: ")
      ans="${ans:-$d_domain}"
      if [[ -n "$ans" ]] && valid_domain "$ans"; then domain=$ans; break; fi
      warn "请输入正确的域名"
    else
      ans=$(ask "1) 域名（填写则启用 TLS + Caddy；留空=不用 TLS；输入 - 清除）${d_domain:+ [$d_domain]}: ")
      if [[ "$ans" == "-" ]]; then domain=""; break; fi
      ans="${ans:-$d_domain}"
      if [[ -z "$ans" ]] || valid_domain "$ans"; then domain=$ans; break; fi
      warn "域名格式不正确"
    fi
  done

  # 2) 端口
  if [[ -n "$domain" ]]; then
    echo "   提示：如果走 Cloudflare CDN，只能使用它支持的 HTTPS 端口："
    echo "         ${CF_PORTS}"
  fi
  while :; do
    if [[ -n "$domain" ]]; then
      ans=$(ask "2) HTTPS 端口（必填）${d_port:+ [$d_port]}: ")
    else
      ans=$(ask "2) 监听端口（留空=随机）${d_port:+ [$d_port]}: ")
    fi
    ans="${ans:-$d_port}"
    if [[ -z "$ans" ]]; then
      if [[ -n "$domain" ]]; then warn "必须输入端口"; continue; fi
      port=$(rand_port); break
    fi
    if ! valid_port "$ans"; then warn "端口无效（1-65535）"; continue; fi
    ans=$(( 10#$ans ))
    if [[ -n "$domain" && "$ans" == 80 ]]; then warn "80 端口用于证书验证，请换一个"; continue; fi
    if ! msg=$(check_port "$ans" "$domain" "$self"); then warn "$msg"; continue; fi
    if [[ -n "$domain" ]] && ! cf_port "$ans"; then
      warn "端口 $ans 不在 Cloudflare 支持的列表内；开启 CDN（橙云）后将无法连接"
    fi
    port=$ans; break
  done

  # 3) UUID
  while :; do
    ans=$(ask "3) UUID [$d_uuid]: ")
    ans="${ans:-$d_uuid}"
    if valid_uuid "$ans"; then uuid=$ans; break; fi
    warn "UUID 格式不正确，应形如 xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx"
  done

  # 4) 路径
  while :; do
    ans=$(ask "4) 路径，如 /ws [$d_path]: ")
    ans="${ans:-$d_path}"
    [[ -n "$ans" && "$ans" != /* ]] && ans="/$ans"
    while [[ "$ans" == */ ]]; do ans="${ans%/}"; done
    if ! valid_path "$ans"; then warn "路径只能含字母、数字及 / _ . -，且不能为空或仅为 /"; continue; fi
    if [[ -n "$domain" ]] && path_taken "$domain" "$port" "$ans" "$self"; then
      warn "该 域名+端口 下已有节点使用此路径"; continue
    fi
    path=$ans; break
  done

  # 5) XHTTP 模式
  mode=""
  if [[ "$net" == xhttp ]]; then
    echo "   XHTTP 模式：1) packet-up（默认，过 CDN 最稳）  2) stream-up（需 CF 开启 gRPC，实验性）"
    while :; do
      ans=$(ask "5) 模式 [$d_mode]: ")
      case "$ans" in
        "")                 mode=$d_mode; break ;;
        1|packet-up)        mode=packet-up; break ;;
        2|stream-up)        mode=stream-up; break ;;
        *)                  warn "请输入 1 或 2" ;;
      esac
    done
  fi

  # 6) 名称
  while :; do
    ans=$(ask "6) 节点名称 [$d_name]: ")
    ans="${ans//\"/}"; ans="${ans//\\/}"
    ans="${ans:-$d_name}"
    if name_taken "$ans" "$self"; then warn "名称已存在"; continue; fi
    name=$ans; break
  done

  # Xray 实际监听端口：域名节点只监听本机随机端口，直连节点直接监听对外端口
  if [[ -n "$domain" ]]; then
    if [[ -n "$d_xport" && -n "$d_domain" && "$d_xport" != "$port" ]]; then
      xport=$d_xport
    else
      xport=$(rand_port)
    fi
    while [[ "$xport" == "$port" ]]; do xport=$(rand_port); done
  else
    xport=$port
  fi

  NEW_NODE=$(jq -n \
    --arg name "$name" --arg proto "$proto" --arg net "$net" --arg mode "$mode" \
    --arg domain "$domain" --argjson port "$port" --argjson xport "$xport" \
    --arg uuid "$uuid" --arg path "$path" --argjson enabled "$d_en" \
    '{name:$name, proto:$proto, net:$net, mode:$mode, domain:$domain, port:$port, xport:$xport, uuid:$uuid, path:$path, enabled:$enabled}')
}

dns_hint() {
  local r
  r=$(getent ahostsv4 "$1" 2>/dev/null | awk '{print $1; exit}')
  [[ -n "$SERVER_IP" ]] || SERVER_IP=$(get_ip)
  if [[ "$r" != "$SERVER_IP" ]]; then
    warn "域名 $1 当前解析到 '${r:-无}'，本机 IP 为 ${SERVER_IP:-未知}。"
    warn "已开启 Cloudflare 橙云属正常；否则请先把 A 记录指向本机，否则证书申请会失败。"
  fi
}

# ------------------------- 功能：新增 / 修改 / 暂停 / 删除 -------------------------
add_node() {
  local proto=$1 net=$2 d port new
  prompt_node "$proto" "$net" -1
  echo
  echo "================ 配置确认 ================"
  show_summary
  echo "=========================================="
  yn y "确认创建？[Y/n]: " || { info "已取消"; return 0; }

  d=$(jq -r '.domain' <<< "$NEW_NODE")
  port=$(jq -r '.port' <<< "$NEW_NODE")
  [[ -n "$d" ]] && dns_hint "$d"

  new=$(jq --argjson n "$NEW_NODE" '. + [$n]' "$NODES_FILE")
  if commit_nodes "$new"; then
    [[ -n "$d" ]] && fw_open 80
    fw_open "$port"
    info "节点已创建并启动，Clash Mihomo 节点配置如下："
    print_clash $(( $(node_count) - 1 ))
  fi
}

edit_node() {
  choose_node "请选择要修改的节点编号" || return 0
  local i=$SEL proto net oldport new
  proto=$(nf "$i" proto); net=$(nf "$i" net); oldport=$(nf "$i" port)
  prompt_node "$proto" "$net" "$i"
  echo
  echo "================ 修改后配置 ================"
  show_summary
  echo "============================================"
  yn y "确认修改？[Y/n]: " || { info "已取消"; return 0; }

  local d port
  d=$(jq -r '.domain' <<< "$NEW_NODE"); port=$(jq -r '.port' <<< "$NEW_NODE")
  [[ -n "$d" ]] && dns_hint "$d"

  new=$(jq --argjson n "$NEW_NODE" --argjson i "$i" '.[$i] = $n' "$NODES_FILE")
  if commit_nodes "$new"; then
    [[ -n "$d" ]] && fw_open 80
    fw_open "$port"
    [[ "$oldport" != "$port" ]] && fw_release "$oldport"
    info "修改完成，新的 Clash Mihomo 节点配置："
    print_clash "$i"
  fi
}

toggle_node() {
  choose_node "暂停/恢复哪个节点" || return 0
  local i=$SEL cur name new
  cur=$(nf "$i" enabled); name=$(nf "$i" name)
  new=$(jq --argjson i "$i" '.[$i].enabled |= not' "$NODES_FILE")
  if commit_nodes "$new"; then
    if [[ "$cur" == true ]]; then info "已暂停节点：$name（配置保留，可随时恢复）"
    else info "已恢复节点：$name"; fi
  fi
}

delete_node() {
  choose_node "请选择要删除的节点编号" || return 0
  local i=$SEL name port new
  name=$(nf "$i" name); port=$(nf "$i" port)
  yn n "确认删除节点 $name？此操作不可恢复 [y/N]: " || { info "已取消"; return 0; }
  new=$(jq --argjson i "$i" 'del(.[$i])' "$NODES_FILE")
  if commit_nodes "$new"; then
    fw_release "$port"
    info "已删除节点：$name"
  fi
}

view_node() {
  choose_node "请选择要查看的节点编号" || return 0
  print_clash "$SEL"
}

# ------------------------- 卸载 -------------------------
uninstall_proto() {
  local p=$1 cnt ports new x
  cnt=$(jq --arg p "$p" '[.[] | select(.proto == $p)] | length' "$NODES_FILE")
  if (( cnt == 0 )); then info "当前没有 $p 节点"; return 0; fi
  yn n "将删除全部 $cnt 个 $p 节点，确认？[y/N]: " || { info "已取消"; return 0; }
  ports=$(jq -r --arg p "$p" '.[] | select(.proto == $p) | .port' "$NODES_FILE")
  new=$(jq --arg p "$p" 'map(select(.proto != $p))' "$NODES_FILE")
  if commit_nodes "$new"; then
    for x in $ports; do fw_release "$x"; done
    info "已卸载全部 $p 节点"
  fi
}

uninstall_all() {
  local ans ports x
  echo
  warn "完全卸载将删除："
  echo "  - 所有节点及本脚本的配置（$STATE_DIR）和 xnode 命令"
  if [[ "$(meta_get XRAY_PREEXIST)" == 1 ]]; then
    echo "  - Xray：系统原本就有，不会卸载，仅还原原配置"
  else
    echo "  - Xray-core（程序、配置、日志、服务文件）"
  fi
  if [[ "$(meta_get CADDY_PREEXIST)" == 1 ]]; then
    echo "  - Caddy：系统原本就有，不会卸载，仅还原原 Caddyfile"
  else
    echo "  - Caddy（软件包、软件源、配置、已申请的证书）"
  fi
  ans=$(ask "确认请输入 yes: ")
  [[ "$ans" == yes ]] || { info "已取消"; return 0; }

  # 防火墙
  ports=$(jq -r '.[].port' "$NODES_FILE" 2>/dev/null | sort -u)
  if ufw_active; then
    for x in $ports; do ufw delete allow "$x/tcp" >/dev/null 2>&1; done
    [[ "$(meta_get CADDY_PREEXIST)" == 1 ]] || ufw delete allow 80/tcp >/dev/null 2>&1
  fi

  # Xray
  systemctl stop xray >/dev/null 2>&1
  systemctl disable xray >/dev/null 2>&1
  if [[ "$(meta_get XRAY_PREEXIST)" == 1 ]]; then
    if [[ -f "$XRAY_CONF.xnode.bak" ]]; then
      mv -f "$XRAY_CONF.xnode.bak" "$XRAY_CONF"
      systemctl restart xray >/dev/null 2>&1
    fi
    rm -f "$XRAY_CONF_TMP"
  else
    rm -f /usr/local/bin/xray /etc/systemd/system/xray.service /etc/systemd/system/xray@.service
    rm -rf /etc/systemd/system/xray.service.d /etc/systemd/system/xray@.service.d \
           /usr/local/etc/xray /usr/local/share/xray /var/log/xray
    systemctl daemon-reload >/dev/null 2>&1
  fi

  # Caddy
  systemctl stop caddy >/dev/null 2>&1
  if [[ "$(meta_get CADDY_PREEXIST)" == 1 ]]; then
    if [[ -f "$CADDYFILE.xnode.bak" ]]; then
      mv -f "$CADDYFILE.xnode.bak" "$CADDYFILE"
      systemctl restart caddy >/dev/null 2>&1
    elif [[ -f "$CADDYFILE" ]] && grep -qF "$MARK" "$CADDYFILE"; then
      rm -f "$CADDYFILE"
    fi
    rm -f "$CADDYFILE.new"
  else
    systemctl disable caddy >/dev/null 2>&1
    DEBIAN_FRONTEND=noninteractive apt-get purge -y caddy >/dev/null 2>&1
    rm -f /etc/apt/sources.list.d/caddy-stable.list /usr/share/keyrings/caddy-stable-archive-keyring.gpg
    rm -rf /etc/caddy /var/lib/caddy /var/log/caddy
    systemctl daemon-reload >/dev/null 2>&1
  fi

  rm -rf "$STATE_DIR"
  rm -f "$SELF_BIN" /tmp/xray-install.sh
  echo
  info "已完全卸载，系统已清理干净。"
  info "如还保留着下载的脚本文件（xnode.sh），可自行删除。"
  exit 0
}

uninstall_menu() {
  echo
  echo "---------------- 卸载 ----------------"
  echo " 1) 卸载全部 VMess 节点"
  echo " 2) 卸载全部 VLESS 节点"
  echo " 3) 完全卸载（Xray / Caddy / 所有节点与配置，全部清理）"
  echo " 0) 返回"
  case "$(ask "请选择: ")" in
    1) uninstall_proto vmess ;;
    2) uninstall_proto vless ;;
    3) uninstall_all ;;
    *) return 0 ;;
  esac
}

# ------------------------- 主菜单 -------------------------
menu() {
  local c
  echo
  echo "==================== xnode 节点管理 ===================="
  list_nodes
  echo "--------------------------------------------------------"
  echo " 1) 新增节点：VMess + WS"
  echo " 2) 新增节点：VLESS + XHTTP"
  echo " 3) 查看节点 / 输出 Clash 配置"
  echo " 4) 修改节点配置"
  echo " 5) 暂停 / 恢复节点"
  echo " 6) 删除节点"
  echo " 7) 卸载"
  echo " 0) 退出"
  c=$(ask "请选择: ")
  case "$c" in
    1) add_node vmess ws;     pause_enter ;;
    2) add_node vless xhttp;  pause_enter ;;
    3) view_node;             pause_enter ;;
    4) edit_node;             pause_enter ;;
    5) toggle_node;           pause_enter ;;
    6) delete_node;           pause_enter ;;
    7) uninstall_menu;        pause_enter ;;
    0) exit 0 ;;
    *) warn "无效选择" ;;
  esac
}

main() {
  [[ $EUID -eq 0 ]] || die "请使用 root 运行"
  command -v apt-get >/dev/null || die "仅支持 Ubuntu / Debian"
  command -v systemctl >/dev/null || die "需要 systemd"
  { : < /dev/tty; } 2>/dev/null || die "需要交互式终端"
  ensure_deps
  init_state
  install_self
  while :; do menu; done
}

[[ -n "${XNODE_SOURCED:-}" ]] || main "$@"
