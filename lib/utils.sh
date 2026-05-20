#!/bin/bash

export RED='\033[31m'
export GREEN='\033[32m'
export YELLOW='\033[33m'
export BLUE='\033[34m'
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

ensure_config_dir() {
    mkdir -p "$(dirname "$CONFIG_FINAL")"
    mkdir -p /var/log/sing-box
}

install_singbox() {
    log_info "正在检测并安装 Sing-box..."
    bash <(curl -fsSL https://sing-box.app/install.sh)
    if [[ $? -eq 0 ]]; then
        log_info "Sing-box 安装成功。"
        chmod +x /usr/local/bin/sing-box 2>/dev/null
    else
        log_error "Sing-box 安装失败，请检查网络或权限。"
        exit 1
    fi
}

check_dependencies() {
    if ! command -v jq &>/dev/null; then
        log_warn "缺少依赖 jq，正在安装..."
        apt-get update && apt-get install -y jq
    fi
    if ! command -v sing-box &>/dev/null; then
        log_warn "未发现 Sing-box，准备安装..."
        install_singbox
    else
        log_info "依赖检查通过。"
    fi
}

validate_json() {
    if ! jq empty "$1" >/dev/null 2>&1; then
        log_error "文件 $1 不是有效的 JSON 格式。"
        return 1
    fi
    return 0
}

setup_metadata() {
    log_info "开始初始化 metadata.json ..."
    local domain dest ip pk sk sid
    read -rp "服务器公网 IP（留空自动检测）: " ip
    [[ -z "$ip" ]] && ip=$(detect_server_ip)
    read -rp "TLS 协议使用的域名: " domain
    read -rp "REALITY 伪装目标（如 www.google.com:443）: " dest
    dest=${dest:-www.google.com:443}

    if command -v sing-box &>/dev/null; then
        local keypair
        keypair=$(sing-box generate reality-keypair 2>/dev/null)
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
            "vless_reality_vision": { "uuid": $u1, "port": 10001 },
            "vless_reality_xhttp":  { "uuid": $u2, "port": 10002 },
            "vless_ws_tls":         { "uuid": $u3, "port": 10003 },
            "vless_grpc_tls":       { "uuid": $u4, "port": 10004 },
            "vless_xhttp_tls":      { "uuid": $u5, "port": 10005 },
            "trojan_ws_tls":        { "password": $p1, "port": 10006 },
            "trojan_grpc_tls":      { "password": $p2, "port": 10007 }
          }
        }' > "$BASE_DIR/metadata.json"

    log_info "metadata.json 已生成。"
}

show_protocol_info() {
    local proto_name=$1
    local ip domain port cred tag path sni
    ip=$(metadata_get '.global.server_ip')
    [[ -z "$ip" || "$ip" == "null" ]] && ip=$(detect_server_ip)
    domain=$(metadata_get '.global.domain')
    port=$(metadata_get ".protocols.${proto_name}.port")
    tag="${proto_name//_/-}"

    echo -e "${BLUE}━━━━━━━━ 节点信息 ━━━━━━━━${NC}"

    case "$proto_name" in
        vless_reality_vision)
            cred=$(metadata_get ".protocols.${proto_name}.uuid")
            sni=$(metadata_get '.global.dest_reality' | cut -d: -f1)
            local pk sid
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
            echo "vless://${cred}@${ip}:${port}?encryption=none&security=reality&sni=${sni}&fp=chrome&pbk=${pk}&sid=${sid}&type=xhttp&path=${path}#${tag}"
            ;;
        vless_ws_tls)
            cred=$(metadata_get ".protocols.${proto_name}.uuid")
            path=$(metadata_get '.global.ws_path')
            echo "vless://${cred}@${domain}:${port}?encryption=none&security=tls&sni=${domain}&type=ws&host=${domain}&path=${path}#${tag}"
            ;;
        vless_grpc_tls)
            cred=$(metadata_get ".protocols.${proto_name}.uuid")
            echo "vless://${cred}@${domain}:${port}?encryption=none&security=tls&sni=${domain}&type=grpc&serviceName=grpc#${tag}"
            ;;
        vless_xhttp_tls)
            cred=$(metadata_get ".protocols.${proto_name}.uuid")
            path=$(metadata_get '.global.xhttp_path')
            echo "vless://${cred}@${domain}:${port}?encryption=none&security=tls&sni=${domain}&type=xhttp&path=${path}#${tag}"
            ;;
        trojan_ws_tls)
            cred=$(metadata_get ".protocols.${proto_name}.password")
            path=$(metadata_get '.global.trojan_ws_path')
            echo "trojan://${cred}@${domain}:${port}?security=tls&sni=${domain}&type=ws&host=${domain}&path=${path}#${tag}"
            ;;
        trojan_grpc_tls)
            cred=$(metadata_get ".protocols.${proto_name}.password")
            echo "trojan://${cred}@${domain}:${port}?security=tls&sni=${domain}&type=grpc&serviceName=trojan-grpc#${tag}"
            ;;
    esac
    echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
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
    read -rp "确认卸载 sing-box 并删除配置？[y/N]: " confirm
    [[ "$confirm" != "y" && "$confirm" != "Y" ]] && return
    systemctl stop sing-box 2>/dev/null
    systemctl disable sing-box 2>/dev/null
    rm -f "$CONFIG_FINAL" "$CONFIG_TMP"
    rm -f "$BASE_DIR/protocols/"*.tmp
    if [[ -x /usr/local/bin/sing-box ]]; then
        bash <(curl -fsSL https://sing-box.app/install.sh) --uninstall 2>/dev/null || true
    fi
    log_info "卸载完成。"
}
