#!/bin/bash

export RED='\033[31m'
export GREEN='\033[32m'
export YELLOW='\033[33m'
export BLUE='\033[34m'
export CYAN='\033[36m'
export NC='\033[0m'

log_info()  { echo -e "${GREEN}[INFO]${NC} $1"; }
log_warn()  { echo -e "${YELLOW}[WARN]${NC} $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} $1"; }

generate_uuid() {
    if command -v sing-box &>/dev/null; then
        sing-box generate uuid 2>/dev/null && return
    fi
    uuidgen 2>/dev/null | tr '[:upper:]' '[:lower:]' || cat /proc/sys/kernel/random/uuid 2>/dev/null
}

generate_password() {
    tr -dc 'A-Za-z0-9' </dev/urandom 2>/dev/null | head -c 16
}

generate_short_id() {
    tr -dc '0-9a-f' </dev/urandom 2>/dev/null | head -c 8
}

detect_server_ip() {
    local ip
    ip=$(curl -4 -s --max-time 5 https://api.ipify.org 2>/dev/null)
    [[ -n "$ip" ]] && echo "$ip" && return
    ip=$(curl -4 -s --max-time 5 https://ifconfig.me 2>/dev/null)
    [[ -n "$ip" ]] && echo "$ip" && return
    hostname -I 2>/dev/null | awk '{print $1}'
}

metadata_get() {
    jq -r "$1" "$BASE_DIR/metadata.json" 2>/dev/null
}

# 解析 sing-box 服务实际使用的 config.json 路径（apt 多为 /etc/sing-box/）
resolve_config_final() {
    local exec_start arg path found=""
    if command -v systemctl &>/dev/null && systemctl list-unit-files sing-box.service &>/dev/null 2>&1; then
        exec_start=$(systemctl show sing-box -p ExecStart --value 2>/dev/null || true)
        if [[ "$exec_start" =~ -c[[:space:]]+([^[:space:]]+) ]]; then
            CONFIG_FINAL="${BASH_REMATCH[1]}"
            found=1
        else
            for arg in $exec_start; do
                if [[ "$arg" == *config.json ]]; then
                    CONFIG_FINAL="$arg"
                    found=1
                    break
                fi
            done
        fi
    fi
    if [[ -z "$found" ]]; then
        for path in /etc/sing-box/config.json /usr/local/etc/sing-box/config.json; do
            if [[ -f "$path" ]]; then
                CONFIG_FINAL="$path"
                found=1
                break
            fi
        done
    fi
    [[ -n "$found" ]] || CONFIG_FINAL="/etc/sing-box/config.json"
    mkdir -p "$(dirname "$CONFIG_FINAL")"
    export CONFIG_FINAL
}

ensure_config_dir() {
    resolve_config_final
    mkdir -p "$(dirname "$CONFIG_FINAL")"
    mkdir -p /var/log/sing-box
}

# 避免写入错误路径后服务仍读另一份默认 Shadowsocks 配置
sync_stale_config_paths() {
    local stale
    for stale in /etc/sing-box/config.json /usr/local/etc/sing-box/config.json; do
        [[ "$stale" != "$CONFIG_FINAL" && -f "$stale" ]] || continue
        log_warn "发现另一份配置文件（服务不会读取）: $stale"
        mv "$stale" "${stale}.bak.$(date +%s)" 2>/dev/null && \
            log_info "已备份为 ${stale}.bak.* ，避免与当前配置冲突。"
    done
}

# 部署后验证 inbounds 是否包含目标协议
verify_deploy_result() {
    local only_proto="${1:-}"
    local tag count has_ss

    if [[ ! -f "$CONFIG_FINAL" ]]; then
        log_error "配置文件不存在: $CONFIG_FINAL"
        return 1
    fi

    count=$(jq -r '.inbounds | length' "$CONFIG_FINAL" 2>/dev/null)
    if [[ -z "$count" || "$count" == "0" || "$count" == "null" ]]; then
        log_error "配置中 inbounds 为空: $CONFIG_FINAL"
        return 1
    fi

    has_ss=$(jq -r '[.inbounds[] | select(.type=="shadowsocks")] | length' "$CONFIG_FINAL" 2>/dev/null)
    if [[ "$has_ss" != "0" && -n "$only_proto" ]]; then
        log_error "配置仍包含 Shadowsocks 入站，未正确覆盖默认配置。"
        return 1
    fi

    if [[ -n "$only_proto" ]]; then
        tag="${only_proto//_/-}"
        if ! jq -e --arg t "$tag" '.inbounds[] | select(.tag == $t)' "$CONFIG_FINAL" &>/dev/null; then
            log_error "配置中未找到 inbound: ${tag}"
            jq -r '.inbounds[] | "  现有: \(.type) / \(.tag) / 端口 \(.listen_port)"' "$CONFIG_FINAL" 2>/dev/null
            return 1
        fi
    fi

    log_info "当前生效 inbound（${CONFIG_FINAL}）:"
    jq -r '.inbounds[] | "  · \(.type)  \(.tag)  → 端口 \(.listen_port)"' "$CONFIG_FINAL" 2>/dev/null
    return 0
}

# 放行 sing-box 监听端口（云厂商安全组仍需手动放行）
open_firewall_port() {
    local port=$1
    [[ -z "$port" || "$port" == "null" ]] && return 0

    if command -v ufw &>/dev/null; then
        if ufw status 2>/dev/null | grep -qi "Status: active"; then
            ufw allow "${port}/tcp" comment "sing-box" >/dev/null 2>&1
            log_info "UFW 已放行 ${port}/tcp"
            return 0
        fi
    fi
    if command -v firewall-cmd &>/dev/null && systemctl is-active firewalld &>/dev/null; then
        firewall-cmd --permanent --add-port="${port}/tcp" >/dev/null 2>&1
        firewall-cmd --reload >/dev/null 2>&1
        log_info "firewalld 已放行 ${port}/tcp"
        return 0
    fi
    if command -v iptables &>/dev/null; then
        if ! iptables -C INPUT -p tcp --dport "$port" -j ACCEPT 2>/dev/null; then
            iptables -I INPUT -p tcp --dport "$port" -j ACCEPT 2>/dev/null
        fi
        log_info "iptables 已放行 ${port}/tcp（重启后可能失效）"
        return 0
    fi
    log_warn "请在本机防火墙/云服务商安全组中放行 TCP 端口 ${port}"
}

open_config_ports() {
    local port
    [[ -f "$CONFIG_FINAL" ]] || return 0
    while IFS= read -r port; do
        [[ -n "$port" && "$port" != "null" ]] && open_firewall_port "$port"
    done < <(jq -r '.inbounds[]?.listen_port // empty' "$CONFIG_FINAL" 2>/dev/null)
}

# 检查服务是否运行、端口是否在监听
check_service_health() {
    local expect_port=$1
    local svc_state

    svc_state=$(systemctl is-active sing-box 2>/dev/null || true)
    if [[ "$svc_state" != "active" ]]; then
        log_error "sing-box 服务未运行（状态: ${svc_state:-unknown}），客户端会出现 connection refused。"
        log_info "最近日志："
        journalctl -u sing-box -n 20 --no-pager 2>/dev/null || true
        return 1
    fi

    if [[ -n "$expect_port" ]]; then
        if ss -tlnp 2>/dev/null | grep -qE ":${expect_port}[[:space:]]" || \
           netstat -tlnp 2>/dev/null | grep -qE ":${expect_port}[[:space:]]"; then
            log_info "端口 ${expect_port}/tcp 正在监听 ✓"
        else
            log_error "端口 ${expect_port} 未监听，外网连接会被拒绝！"
            log_info "当前监听列表："
            ss -tlnp 2>/dev/null | grep -E 'sing-box|LISTEN' || ss -tlnp 2>/dev/null | head -15
            return 1
        fi
    fi
    return 0
}

resolve_singbox_bin() {
    local candidate
    for candidate in \
        "$(command -v sing-box 2>/dev/null)" \
        /usr/local/bin/sing-box \
        /usr/bin/sing-box; do
        if [[ -n "$candidate" && -x "$candidate" ]]; then
            echo "$candidate"
            return 0
        fi
    done
    return 1
}

install_singbox() {
    log_info "正在安装 Sing-box（官方脚本）..."
    if ! bash <(curl -fsSL https://sing-box.app/install.sh); then
        log_error "Sing-box 安装失败，请检查网络或 root 权限。"
        return 1
    fi
    SINGBOX_BIN=$(resolve_singbox_bin) || true
    if [[ -z "$SINGBOX_BIN" ]]; then
        log_error "安装完成但未找到 sing-box 可执行文件。"
        return 1
    fi
    chmod +x "$SINGBOX_BIN" 2>/dev/null
    log_info "Sing-box 已安装: $SINGBOX_BIN ($("$SINGBOX_BIN" version 2>/dev/null | head -1))"
    resolve_config_final
    log_info "服务将使用配置: $CONFIG_FINAL"
    return 0
}

ensure_singbox() {
    SINGBOX_BIN=$(resolve_singbox_bin) || true
    if [[ -n "$SINGBOX_BIN" ]]; then
        return 0
    fi
    log_warn "未找到 sing-box，正在自动安装..."
    install_singbox
}

check_dependencies() {
    if ! command -v jq &>/dev/null; then
        log_warn "缺少依赖 jq，正在安装..."
        apt-get update && apt-get install -y jq
    fi
    ensure_singbox || exit 1
    resolve_config_final
    log_info "依赖检查通过，sing-box: $SINGBOX_BIN"
    log_info "服务配置文件: $CONFIG_FINAL"
}

validate_json() {
    if ! jq empty "$1" >/dev/null 2>&1; then
        log_error "文件 $1 不是有效的 JSON 格式。"
        return 1
    fi
    return 0
}

# 菜单顶部：系统与服务状态检测
show_system_status() {
    local ip domain dest meta_label svc_label version inbound_line
    local config_path inbound_count

    resolve_config_final
    config_path="${CONFIG_FINAL:-/etc/sing-box/config.json}"

    echo -e "${CYAN}  >> 系统状态检测${NC}"

    ip=$(metadata_get '.global.server_ip')
    [[ -z "$ip" || "$ip" == "null" ]] && ip=$(detect_server_ip)
    [[ -z "$ip" ]] && ip="未检测到"
    echo -e "  公网 IP        : ${ip}"

    if is_metadata_initialized; then
        meta_label="${GREEN}已初始化${NC}"
        domain=$(metadata_get '.global.domain')
        dest=$(metadata_get '.global.dest_reality')
        [[ "$domain" == "yourdomain.com" || -z "$domain" || "$domain" == "null" ]] && domain="${YELLOW}未设置${NC}"
    else
        meta_label="${YELLOW}未初始化${NC}"
        domain="${YELLOW}—${NC}"
        dest="${YELLOW}—${NC}"
    fi
    echo -e "  配置 (metadata): ${meta_label}"
    echo -e "  TLS 域名        : ${domain}"
    echo -e "  REALITY 伪装    : ${dest}"

    SINGBOX_BIN=$(resolve_singbox_bin) || true
    if [[ -n "$SINGBOX_BIN" ]]; then
        version=$("$SINGBOX_BIN" version 2>/dev/null | head -1)
        inbound_count=0
        [[ -f "$config_path" ]] && \
            inbound_count=$(jq -r '.inbounds | length' "$config_path" 2>/dev/null)
        if [[ "$inbound_count" =~ ^[1-9][0-9]*$ ]]; then
            echo -e "  Sing-box        : ${GREEN}已安装 · 已部署${NC}  ${version:-}"
        else
            echo -e "  Sing-box        : ${YELLOW}已安装 · 未部署节点${NC}  ${version:-}"
        fi
        echo -e "  程序路径        : ${SINGBOX_BIN}"
    else
        echo -e "  Sing-box        : ${RED}未安装${NC}"
    fi

    if [[ -n "$SINGBOX_BIN" ]] && systemctl list-unit-files sing-box.service &>/dev/null 2>&1; then
        case "$(systemctl is-active sing-box 2>/dev/null)" in
            active)   svc_label="${GREEN}运行中 (active)${NC}" ;;
            inactive) svc_label="${YELLOW}已停止 (inactive)${NC}" ;;
            failed)   svc_label="${RED}异常 (failed)${NC}" ;;
            *)        svc_label="${YELLOW}$(systemctl is-active sing-box 2>/dev/null)${NC}" ;;
        esac
        if systemctl is-enabled sing-box &>/dev/null 2>&1; then
            echo -e "  开机自启        : ${GREEN}已启用${NC}"
        else
            echo -e "  开机自启        : ${YELLOW}未启用${NC}"
        fi
    elif [[ -z "$SINGBOX_BIN" ]]; then
        svc_label="${YELLOW}—${NC}"
    else
        svc_label="${YELLOW}未注册 systemd 服务${NC}"
    fi
    echo -e "  服务状态        : ${svc_label}"

    if [[ -f "$config_path" ]] && [[ "$inbound_count" =~ ^[1-9][0-9]*$ ]]; then
        echo -e "  运行配置        : ${GREEN}已部署${NC}  ${config_path}"
        while IFS= read -r inbound_line; do
            [[ -n "$inbound_line" ]] && echo -e "  ${inbound_line}"
        done < <(jq -r '.inbounds[]? | "监听端口        : \(.listen_port)  (\(.tag))"' "$config_path" 2>/dev/null)
    else
        echo -e "  运行配置        : ${YELLOW}未部署${NC}"
        if is_metadata_initialized && [[ -f "$BASE_DIR/metadata.json" ]]; then
            echo -e "  ${YELLOW}预设端口（metadata，仅供参考）:${NC}"
            while IFS= read -r inbound_line; do
                [[ -n "$inbound_line" ]] && echo -e "  ${inbound_line}"
            done < <(jq -r '.protocols | to_entries[] | "    \(.value.port)  (\(.key))"' "$BASE_DIR/metadata.json" 2>/dev/null)
        fi
    fi
}

# 检测 metadata 是否已完成初始化（可按协议细检）
is_metadata_initialized() {
    local proto_name="${1:-}"
    local meta="$BASE_DIR/metadata.json"
    local cred domain sk

    [[ -f "$meta" ]] || return 1
    validate_json "$meta" || return 1

    if [[ -n "$proto_name" ]]; then
        cred=$(metadata_get ".protocols.${proto_name} | .uuid // .password // \"\"")
        [[ -n "$cred" && "$cred" != "null" && "$cred" != YOUR_* ]] || return 1

        if [[ "$proto_name" == *"reality"* ]]; then
            sk=$(metadata_get '.global.reality_private_key')
            [[ -n "$sk" && "$sk" != "null" && "$sk" != YOUR_* ]] || return 1
        else
            domain=$(metadata_get '.global.domain')
            [[ -n "$domain" && "$domain" != "null" && "$domain" != "yourdomain.com" ]] || return 1
        fi
        return 0
    fi

    # 全量检测：仍存在占位符则视为未初始化
    if grep -qE 'YOUR_|yourdomain\.com' "$meta" 2>/dev/null; then
        return 1
    fi
    return 0
}

# 安装协议前自动引导初始化向导
ensure_metadata() {
    local proto_name="${1:-}"

    if is_metadata_initialized "$proto_name"; then
        return 0
    fi

    log_warn "检测到 metadata.json 尚未配置（或仍为模板占位符）。"
    read -rp "是否现在运行初始化向导？[Y/n]: " ans
    if [[ "$ans" == "n" || "$ans" == "N" ]]; then
        log_error "已取消。请先完成初始化，或手动编辑 metadata.json。"
        return 1
    fi

    setup_metadata

    if is_metadata_initialized "$proto_name"; then
        log_info "配置初始化完成。"
        return 0
    fi

    log_error "初始化后配置仍不完整，请检查 metadata.json。"
    return 1
}

setup_metadata() {
    log_info "开始初始化 metadata.json ..."
    ensure_singbox || true
    local domain dest ip pk sk sid
    read -rp "服务器公网 IP（留空自动检测）: " ip
    [[ -z "$ip" ]] && ip=$(detect_server_ip)
    read -rp "TLS 协议使用的域名: " domain
    read -rp "REALITY 伪装目标（默认 www.bing.com:443）: " dest
    dest=${dest:-www.bing.com:443}

    if [[ -n "$SINGBOX_BIN" ]]; then
        local keypair
        keypair=$("$SINGBOX_BIN" generate reality-keypair 2>/dev/null)
        pk=$(echo "$keypair" | awk '/PublicKey/{print $2}')
        sk=$(echo "$keypair" | awk '/PrivateKey/{print $2}')
    fi
    sid=$(generate_short_id)

    local u1 u2 u3 u4 u5 p1 p2
    u1=$(generate_uuid); u2=$(generate_uuid); u3=$(generate_uuid)
    u4=$(generate_uuid); u5=$(generate_uuid)
    p1=$(generate_password); p2=$(generate_password)

    jq -n \
        --arg ip "$ip" \
        --arg domain "$domain" \
        --arg dest "$dest" \
        --arg pk "${pk:-YOUR_PUBLIC_KEY}" \
        --arg sk "${sk:-YOUR_PRIVATE_KEY}" \
        --arg sid "$sid" \
        --arg u1 "$u1" --arg u2 "$u2" --arg u3 "$u3" --arg u4 "$u4" --arg u5 "$u5" \
        --arg p1 "$p1" --arg p2 "$p2" \
        '{
          "_comment": "由初始化向导生成",
          "global": {
            "server_ip": $ip,
            "domain": $domain,
            "dest_reality": $dest,
            "reality_public_key": $pk,
            "reality_private_key": $sk,
            "reality_short_id": $sid,
            "xhttp_path": "/xhttp",
            "ws_path": "/ws",
            "trojan_ws_path": "/trojan-ws"
          },
          "protocols": {
            "vless_reality_vision": { "uuid": $u1, "port": 443 },
            "vless_reality_xhttp":  { "uuid": $u2, "port": 443 },
            "vless_ws_tls":         { "uuid": $u3, "port": 443 },
            "vless_grpc_tls":       { "uuid": $u4, "port": 443 },
            "vless_xhttp_tls":      { "uuid": $u5, "port": 443 },
            "trojan_ws_tls":        { "password": $p1, "port": 443 },
            "trojan_grpc_tls":      { "password": $p2, "port": 443 }
          }
        }' > "$BASE_DIR/metadata.json"

    log_info "metadata.json 已生成。"
}

urlencode() {
    jq -nr --arg v "$1" '$v|@uri' 2>/dev/null || python3 -c "import urllib.parse; print(urllib.parse.quote('''$1''', safe=''))" 2>/dev/null || echo "$1"
}

_print_param() {
    printf "  %-16s : %s\n" "$1" "$2"
}

get_protocol_label() {
    case "$1" in
        vless_reality_vision) echo "VLESS-REALITY-Vision" ;;
        vless_reality_xhttp)  echo "VLESS-REALITY-XHTTP" ;;
        vless_ws_tls)         echo "VLESS-WS-TLS" ;;
        vless_grpc_tls)       echo "VLESS-GRPC-TLS" ;;
        vless_xhttp_tls)      echo "VLESS-XHTTP-TLS" ;;
        trojan_ws_tls)        echo "TROJAN-WS-TLS" ;;
        trojan_grpc_tls)      echo "TROJAN-GRPC-TLS" ;;
        *) echo "$1" ;;
    esac
}

# 配置 tag → 内部协议名
tag_to_proto_name() {
    case "$1" in
        vless-reality-vision) echo "vless_reality_vision" ;;
        vless-reality-xhttp)  echo "vless_reality_xhttp" ;;
        vless-ws-tls)         echo "vless_ws_tls" ;;
        vless-grpc-tls)       echo "vless_grpc_tls" ;;
        vless-xhttp-tls)      echo "vless_xhttp_tls" ;;
        trojan-ws-tls)        echo "trojan_ws_tls" ;;
        trojan-grpc-tls)      echo "trojan_grpc_tls" ;;
        *) echo "" ;;
    esac
}

# 从已部署配置读取实际监听端口
get_deployed_port() {
    local proto_name=$1
    local tag="${proto_name//_/-}"
    [[ -f "$CONFIG_FINAL" ]] || return 1
    jq -r --arg t "$tag" '.inbounds[]? | select(.tag == $t) | .listen_port' "$CONFIG_FINAL" 2>/dev/null
}

# 列出当前 config.json 中已部署的协议
list_deployed_protocols() {
    local tag proto
    if [[ ! -f "$CONFIG_FINAL" ]]; then
        return 1
    fi
    while IFS= read -r tag; do
        [[ -z "$tag" ]] && continue
        proto=$(tag_to_proto_name "$tag")
        [[ -n "$proto" ]] && echo "$proto"
    done < <(jq -r '.inbounds[]?.tag // empty' "$CONFIG_FINAL" 2>/dev/null)
}

# [c] 查看当前已安装协议的信息、链接与二维码
view_installed_protocols() {
    local -a deployed=()
    local proto

    if [[ ! -f "$CONFIG_FINAL" ]]; then
        log_error "尚未部署任何协议，请先通过 [1]-[7] 安装。"
        return 1
    fi

    if ! is_metadata_initialized; then
        log_error "metadata.json 未初始化，无法生成节点链接。请先运行 [i]。"
        return 1
    fi

    while IFS= read -r proto; do
        [[ -n "$proto" ]] && deployed+=("$proto")
    done < <(list_deployed_protocols)

    if [[ ${#deployed[@]} -eq 0 ]]; then
        log_warn "配置文件中未找到可识别的已部署协议。"
        return 1
    fi

    echo ""
    log_info "当前已部署 ${#deployed[@]} 个协议，详情如下："
    for proto in "${deployed[@]}"; do
        show_protocol_info "$proto" "$(get_protocol_label "$proto")" "view"
    done
}

# 生成客户端共享链接（stdout 输出一行 URI）
build_share_link() {
    local proto_name=$1
    local ip domain port cred tag path sni pk sid enc_path dest

    ip=$(metadata_get '.global.server_ip')
    [[ -z "$ip" || "$ip" == "null" ]] && ip=$(detect_server_ip)
    domain=$(metadata_get '.global.domain')
    port=$(metadata_get ".protocols.${proto_name}.port")
    tag="${proto_name//_/-}"
    local deployed_port
    deployed_port=$(get_deployed_port "$proto_name")
    [[ -n "$deployed_port" && "$deployed_port" != "null" ]] && port="$deployed_port"

    case "$proto_name" in
        vless_reality_vision)
            cred=$(metadata_get ".protocols.${proto_name}.uuid")
            sni=$(metadata_get '.global.dest_reality' | cut -d: -f1)
            pk=$(metadata_get '.global.reality_public_key')
            sid=$(metadata_get '.global.reality_short_id')
            echo "vless://${cred}@${ip}:${port}?encryption=none&flow=xtls-rprx-vision&security=reality&sni=${sni}&fp=chrome&pbk=${pk}&sid=${sid}&type=tcp#${tag}"
            ;;
        vless_reality_xhttp)
            cred=$(metadata_get ".protocols.${proto_name}.uuid")
            sni=$(metadata_get '.global.dest_reality' | cut -d: -f1)
            pk=$(metadata_get '.global.reality_public_key')
            sid=$(metadata_get '.global.reality_short_id')
            path=$(metadata_get '.global.xhttp_path')
            enc_path=$(urlencode "$path")
            echo "vless://${cred}@${ip}:${port}?encryption=none&security=reality&sni=${sni}&fp=chrome&pbk=${pk}&sid=${sid}&type=xhttp&path=${enc_path}#${tag}"
            ;;
        vless_ws_tls)
            cred=$(metadata_get ".protocols.${proto_name}.uuid")
            path=$(metadata_get '.global.ws_path')
            enc_path=$(urlencode "$path")
            echo "vless://${cred}@${domain}:${port}?encryption=none&security=tls&sni=${domain}&type=ws&host=${domain}&path=${enc_path}#${tag}"
            ;;
        vless_grpc_tls)
            cred=$(metadata_get ".protocols.${proto_name}.uuid")
            echo "vless://${cred}@${domain}:${port}?encryption=none&security=tls&sni=${domain}&type=grpc&serviceName=grpc#${tag}"
            ;;
        vless_xhttp_tls)
            cred=$(metadata_get ".protocols.${proto_name}.uuid")
            path=$(metadata_get '.global.xhttp_path')
            enc_path=$(urlencode "$path")
            echo "vless://${cred}@${domain}:${port}?encryption=none&security=tls&sni=${domain}&type=xhttp&path=${enc_path}#${tag}"
            ;;
        trojan_ws_tls)
            cred=$(metadata_get ".protocols.${proto_name}.password")
            path=$(metadata_get '.global.trojan_ws_path')
            enc_path=$(urlencode "$path")
            echo "trojan://${cred}@${domain}:${port}?security=tls&sni=${domain}&type=ws&host=${domain}&path=${enc_path}#${tag}"
            ;;
        trojan_grpc_tls)
            cred=$(metadata_get ".protocols.${proto_name}.password")
            echo "trojan://${cred}@${domain}:${port}?security=tls&sni=${domain}&type=grpc&serviceName=trojan-grpc#${tag}"
            ;;
        *)
            return 1
            ;;
    esac
}

ensure_qrencode() {
    if command -v qrencode &>/dev/null; then
        return 0
    fi
    log_info "正在安装 qrencode（用于生成二维码）..."
    apt-get update && apt-get install -y qrencode
}

show_qrcode() {
    local link=$1
    ensure_qrencode || return 1
    echo -e "${GREEN}  >> 扫码导入（终端二维码）${NC}"
    qrencode -t ANSIUTF8 -m 2 "$link" 2>/dev/null || qrencode -t ANSI "$link"
}

# 展示参数、共享链接、二维码，并保存到 output/（mode: install | view）
show_protocol_info() {
    local proto_name=$1
    local label="${2:-$(get_protocol_label "$proto_name")}"
    local mode="${3:-install}"
    local title link ip domain port cred path sni pk sid dest hs_server hs_port
    local output_dir="$BASE_DIR/output"

    ip=$(metadata_get '.global.server_ip')
    [[ -z "$ip" || "$ip" == "null" ]] && ip=$(detect_server_ip)
    domain=$(metadata_get '.global.domain')
    port=$(metadata_get ".protocols.${proto_name}.port")
    local deployed_port
    deployed_port=$(get_deployed_port "$proto_name")
    [[ -n "$deployed_port" && "$deployed_port" != "null" ]] && port="$deployed_port"
    link=$(build_share_link "$proto_name") || {
        log_error "无法生成共享链接: $proto_name"
        return 1
    }

    mkdir -p "$output_dir"
    echo "$link" > "${output_dir}/${proto_name}.txt"
    if ensure_qrencode; then
        qrencode -o "${output_dir}/${proto_name}.png" -s 8 -m 2 "$link" 2>/dev/null
    fi

    echo ""
    if [[ "$mode" == "view" ]]; then
        echo -e "${BLUE}━━━━━━━━━━━━━━━━ 当前节点信息 ━━━━━━━━━━━━━━━━━━━━${NC}"
    else
        echo -e "${BLUE}━━━━━━━━━━━━━━━━ 安装成功 · 节点信息 ━━━━━━━━━━━━━━━━${NC}"
    fi
    _print_param "协议名称" "$label"
    _print_param "节点标签" "${proto_name//_/-}"

    case "$proto_name" in
        vless_reality_vision|vless_reality_xhttp)
            cred=$(metadata_get ".protocols.${proto_name}.uuid")
            dest=$(metadata_get '.global.dest_reality')
            hs_server="${dest%:*}"
            hs_port="${dest##*:}"
            [[ "$hs_server" == "$dest" ]] && hs_port=443
            sni=$hs_server
            pk=$(metadata_get '.global.reality_public_key')
            sid=$(metadata_get '.global.reality_short_id')
            _print_param "协议类型" "VLESS + REALITY"
            _print_param "服务器地址" "$ip"
            _print_param "端口" "$port"
            _print_param "UUID" "$cred"
            [[ "$proto_name" == "vless_reality_vision" ]] && _print_param "传输方式" "TCP (Vision)"
            [[ "$proto_name" == "vless_reality_xhttp" ]] && _print_param "传输方式" "XHTTP"
            [[ "$proto_name" == "vless_reality_vision" ]] && _print_param "流控 (flow)" "xtls-rprx-vision"
            [[ "$proto_name" == "vless_reality_xhttp" ]] && _print_param "路径 (path)" "$(metadata_get '.global.xhttp_path')"
            _print_param "加密" "none"
            _print_param "安全 (security)" "reality"
            _print_param "SNI" "$sni"
            _print_param "指纹 (fp)" "chrome"
            _print_param "Public Key" "$pk"
            _print_param "Short ID" "$sid"
            _print_param "伪装目标" "${hs_server}:${hs_port}"
            ;;
        vless_ws_tls|vless_xhttp_tls)
            cred=$(metadata_get ".protocols.${proto_name}.uuid")
            [[ "$proto_name" == "vless_ws_tls" ]] && path=$(metadata_get '.global.ws_path') || path=$(metadata_get '.global.xhttp_path')
            _print_param "协议类型" "VLESS + TLS"
            _print_param "服务器地址" "$domain"
            _print_param "端口" "$port"
            _print_param "UUID" "$cred"
            [[ "$proto_name" == "vless_ws_tls" ]] && _print_param "传输方式" "WebSocket"
            [[ "$proto_name" == "vless_xhttp_tls" ]] && _print_param "传输方式" "XHTTP"
            _print_param "路径 (path)" "$path"
            _print_param "SNI" "$domain"
            _print_param "安全 (security)" "tls"
            ;;
        vless_grpc_tls)
            cred=$(metadata_get ".protocols.${proto_name}.uuid")
            _print_param "协议类型" "VLESS + TLS"
            _print_param "服务器地址" "$domain"
            _print_param "端口" "$port"
            _print_param "UUID" "$cred"
            _print_param "传输方式" "gRPC"
            _print_param "Service Name" "grpc"
            _print_param "SNI" "$domain"
            _print_param "安全 (security)" "tls"
            ;;
        trojan_ws_tls|trojan_grpc_tls)
            cred=$(metadata_get ".protocols.${proto_name}.password")
            if [[ "$proto_name" == "trojan_ws_tls" ]]; then
                path=$(metadata_get '.global.trojan_ws_path')
                _print_param "传输方式" "WebSocket"
                _print_param "路径 (path)" "$path"
            else
                _print_param "传输方式" "gRPC"
                _print_param "Service Name" "trojan-grpc"
            fi
            _print_param "协议类型" "Trojan + TLS"
            _print_param "服务器地址" "$domain"
            _print_param "端口" "$port"
            _print_param "密码" "$cred"
            _print_param "SNI" "$domain"
            _print_param "安全 (security)" "tls"
            ;;
    esac

    echo -e "${BLUE}────────────────────────────────────────────────────${NC}"
    echo -e "${GREEN}  >> 共享链接（复制到客户端导入）${NC}"
    echo "$link"
    echo -e "${BLUE}────────────────────────────────────────────────────${NC}"

    show_qrcode "$link" || log_warn "二维码生成失败，请使用上方链接手动导入。"

    echo -e "${BLUE}────────────────────────────────────────────────────${NC}"
    log_info "链接已保存: ${output_dir}/${proto_name}.txt"
    [[ -f "${output_dir}/${proto_name}.png" ]] && \
        log_info "二维码已保存: ${output_dir}/${proto_name}.png"
    echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo ""
}

show_traffic() {
    if ! command -v vnstat &>/dev/null; then
        log_info "正在安装 vnstat..."
        apt-get update && apt-get install -y vnstat
        systemctl enable --now vnstat
    fi
    local iface
    iface=$(ip -o -4 route show to default 2>/dev/null | awk '{print $5; exit}')
    iface=${iface:-eth0}
    log_info "当前流量统计（接口 ${iface}）："
    vnstat -i "$iface" -h 24 2>/dev/null || vnstat -h 24
}

enable_bbr() {
    log_info "正在配置 TCP BBR 加速..."
    if ! grep -q "tcp_bbr" /etc/modules-load.d/bbr.conf 2>/dev/null; then
        echo "tcp_bbr" >> /etc/modules-load.d/bbr.conf
        echo "net.core.default_qdisc=fq" >> /etc/sysctl.conf
        echo "net.ipv4.tcp_congestion_control=bbr" >> /etc/sysctl.conf
        sysctl -p
        log_info "BBR 已启用。"
    else
        log_warn "BBR 已处于开启状态。"
    fi
}

uninstall_singbox() {
    read -rp "确认卸载 sing-box（停止服务、删除配置、卸载程序包）？[y/N]: " confirm
    [[ "$confirm" != "y" && "$confirm" != "Y" ]] && return

    log_info "正在停止 sing-box 服务..."
    systemctl stop sing-box 2>/dev/null
    systemctl disable sing-box 2>/dev/null
    systemctl reset-failed sing-box 2>/dev/null

    resolve_config_final
    log_info "正在删除节点配置..."
    local cfg dir
    for cfg in \
        "$CONFIG_FINAL" "$CONFIG_TMP" \
        /etc/sing-box/config.json \
        /usr/local/etc/sing-box/config.json; do
        [[ -n "$cfg" ]] || continue
        rm -f "$cfg"
        rm -f "${cfg}.bak."* 2>/dev/null
    done
    for dir in /etc/sing-box /usr/local/etc/sing-box; do
        [[ -d "$dir" ]] && rmdir "$dir" 2>/dev/null
    done
    rm -f "$BASE_DIR/protocols/"*.tmp
    rm -rf "$BASE_DIR/output"

    log_info "正在卸载 sing-box 程序..."
    if command -v apt-get &>/dev/null && dpkg -l sing-box &>/dev/null 2>&1; then
        DEBIAN_FRONTEND=noninteractive apt-get remove -y --purge sing-box 2>/dev/null \
            || DEBIAN_FRONTEND=noninteractive apt-get remove -y sing-box
    elif command -v dnf &>/dev/null && rpm -q sing-box &>/dev/null 2>&1; then
        dnf remove -y sing-box
    elif command -v rpm &>/dev/null && rpm -q sing-box &>/dev/null 2>&1; then
        rpm -e sing-box
    elif command -v pacman &>/dev/null && pacman -Q sing-box &>/dev/null 2>&1; then
        pacman -Rns --noconfirm sing-box
    else
        log_warn "未通过包管理器安装，尝试删除二进制文件..."
        rm -f /usr/bin/sing-box /usr/local/bin/sing-box
    fi

    systemctl daemon-reload 2>/dev/null
    SINGBOX_BIN=""
    CONFIG_FINAL=""

    if resolve_singbox_bin &>/dev/null; then
        log_warn "程序仍存在: $(resolve_singbox_bin)，请手动执行: apt-get remove -y sing-box"
    else
        log_info "sing-box 程序已卸载。"
    fi
    log_info "节点配置已清除；metadata.json 已保留，可直接重新安装协议。"
}
