#!/bin/bash

# =============================================
# SING-BOX 协议管理器
# 版本: v1.6
# 更新日期: 2026-05-20
# 作者: linuxhobby ( assisted by Grok )
# 功能: 多协议一键部署 + Reality / WS / gRPC 支持 + 客户端链接 + 二维码
# =============================================

BASE_DIR="$(cd "$(dirname "$0")" && pwd)"
CONFIG_TMP="/tmp/sing-box-config.tmp"
CONFIG_FINAL="/usr/local/etc/sing-box/config.json"
METADATA="$BASE_DIR/metadata.json"

source "$BASE_DIR/lib/utils.sh"
check_dependencies

# ==================== process_single (支持前4个协议) ====================
process_single() {
    local proto_name=$1
    local proto_file="$BASE_DIR/protocols/${proto_name}.json"
    local tmp_file="$BASE_DIR/protocols/${proto_name}.tmp"

    log_info "正在处理协议: $proto_name"

    if [[ "$proto_name" == *"reality"* ]]; then
        jq --arg uuid "$(jq -r ".protocols.$proto_name.uuid" "$METADATA")" \
           --arg dest "$(jq -r '.global.dest_reality' "$METADATA")" \
           --arg pk "$(jq -r '.global.reality_public_key' "$METADATA")" \
           --arg sid "$(jq -r '.global.reality_short_id' "$METADATA")" \
           '.users[0].uuid = $uuid |
            .tls.reality.handshake = $dest |
            .tls.reality.public_key = $pk |
            .tls.reality.short_id = $sid' \
           "$proto_file" > "$tmp_file"
    elif [[ "$proto_name" == *"xhttp"* ]]; then
        jq --arg cred "$(jq -r ".protocols.$proto_name | .uuid // .password" "$METADATA")" \
           --arg domain "$(jq -r '.global.domain' "$METADATA")" \
           --arg path "$(jq -r '.global.xhttp_path' "$METADATA")" \
           '.users[0] |= (if .uuid then .uuid = $cred else .password = $cred end) |
            .transport.path = $path |
            .tls.server_name = $domain' \
           "$proto_file" > "$tmp_file"
    else
        jq --arg cred "$(jq -r ".protocols.$proto_name | .uuid // .password" "$METADATA")" \
           --arg domain "$(jq -r '.global.domain' "$METADATA")" \
           '.users[0] |= (if .uuid then .uuid = $cred else .password = $cred end) |
            .tls.server_name = $domain' \
           "$proto_file" > "$tmp_file"
    fi

    if ! validate_json "$tmp_file"; then
        log_error "协议 $proto_name 配置生成失败"
        rm -f "$tmp_file"
        return 1
    fi
}

# ==================== deploy ====================
deploy() {
    local tmp_files=("$BASE_DIR/protocols/"*.tmp)
    
    if [[ ! -f "${tmp_files[0]}" ]]; then
        log_error "没有找到临时配置文件"
        return 1
    fi

    log_info "正在合并配置并校验..."
    jq -s -f "$BASE_DIR/lib/processor.jq" "$BASE_DIR/base.json" "${tmp_files[@]}" > "$CONFIG_TMP"

    if /usr/local/bin/sing-box check -c "$CONFIG_TMP"; then
        mv "$CONFIG_TMP" "$CONFIG_FINAL"
        systemctl restart sing-box
        log_info "✅ 部署成功！配置已生效"
        generate_client_links
    else
        log_error "❌ 配置校验失败，已放弃部署"
        rm -f "$CONFIG_TMP"
    fi

    rm -f "$BASE_DIR/protocols/"*.tmp
}

# ==================== 客户端链接生成 (前4个协议) ====================
generate_client_links() {
    log_info "生成客户端链接和二维码..."
    
    # VLESS-REALITY-Vision
    uuid1=$(jq -r '.protocols.vless_reality_vision.uuid' "$METADATA")
    pk=$(jq -r '.global.reality_public_key' "$METADATA")
    link1="vless://$uuid1@YOUR_SERVER_IP:10001?security=reality&fp=chrome&pbk=$pk&sni=www.google.com&type=tcp&flow=xtls-rprx-vision#VLESS-REALITY-Vision"
    echo -e "\n📱 VLESS-REALITY-Vision:\n$link1"
    command -v qrencode &> /dev/null && echo "$link1" | qrencode -t ANSI

    # VLESS-REALITY-XHTTP
    uuid2=$(jq -r '.protocols.vless_reality_xhttp.uuid' "$METADATA")
    link2="vless://$uuid2@YOUR_SERVER_IP:10002?security=reality&fp=chrome&pbk=$pk&sni=www.google.com&type=xhttp#VLESS-REALITY-XHTTP"
    echo -e "\n📱 VLESS-REALITY-XHTTP:\n$link2"
    command -v qrencode &> /dev/null && echo "$link2" | qrencode -t ANSI

    # VLESS-WS-TLS (第3个)
    uuid3=$(jq -r '.protocols.vless_ws_tls.uuid' "$METADATA")
    domain=$(jq -r '.global.domain' "$METADATA")
    link3="vless://$uuid3@YOUR_SERVER_IP:10003?security=tls&sni=$domain&type=ws&path=/ws#VLESS-WS-TLS"
    echo -e "\n📱 VLESS-WS-TLS:\n$link3"
    command -v qrencode &> /dev/null && echo "$link3" | qrencode -t ANSI

    # VLESS-GRPC-TLS (第4个)
    uuid4=$(jq -r '.protocols.vless_grpc_tls.uuid' "$METADATA")
    link4="vless://$uuid4@YOUR_SERVER_IP:10004?security=tls&sni=$domain&type=grpc&serviceName=grpc#VLESS-GRPC-TLS"
    echo -e "\n📱 VLESS-GRPC-TLS:\n$link4"
    command -v qrencode &> /dev/null && echo "$link4" | qrencode -t ANSI
}

# ==================== 初始化 ====================
init_config() {
    if [[ ! -f "$METADATA" ]] || [[ "$(jq -r '.global.domain' "$METADATA")" == "yourdomain.com" ]]; then
        log_info "首次运行，进入初始化配置..."
        read -p "请输入域名 (Reality 可留空): " domain
        [[ -n "$domain" ]] && jq --arg d "$domain" '.global.domain = $d' "$METADATA" > tmp && mv tmp "$METADATA"
        
        # 生成 UUIDs
        for proto in vless_reality_vision vless_reality_xhttp vless_ws_tls vless_grpc_tls; do
            if [[ -z "$(jq -r ".protocols.$proto.uuid" "$METADATA")" ]] || [[ "$(jq -r ".protocols.$proto.uuid" "$METADATA")" == "YOUR_*" ]]; then
                new_uuid=$(sing-box generate uuid)
                jq --arg u "$new_uuid" --arg p "$proto" '.protocols[$p].uuid = $u' "$METADATA" > tmp && mv tmp "$METADATA"
                log_info "生成 $proto UUID: $new_uuid"
            fi
        done
        log_info "初始化完成！"
    fi
}

# ==================== 菜单 v1.6 ====================
show_menu() {
    clear
    echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "  ${YELLOW}SING-BOX 协议管理器 v1.6${NC}"
    echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "  [1] VLESS-REALITY-Vision (已完善)"
    echo -e "  [2] VLESS-REALITY-XHTTP (已完善)"
    echo -e "  [3] VLESS-WS-TLS (已完善)"
    echo -e "  [4] VLESS-GRPC-TLS (已完善)"
    echo -e "  [c] 批量部署全部"
    echo -e "  [i] 重新初始化配置"
    echo -e "  [q] 退出"
    echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
}

init_config

while true; do
    show_menu
    read -p "指令: " choice
    case $choice in
        1) process_single "vless_reality_vision"; deploy ;;
        2) process_single "vless_reality_xhttp"; deploy ;;
        3) process_single "vless_ws_tls"; deploy ;;
        4) process_single "vless_grpc_tls"; deploy ;;
        c) for f in "$BASE_DIR"/protocols/*.json; do process_single "$(basename "$f" .json)"; done; deploy ;;
        i) init_config ;;
        q) exit 0 ;;
        *) echo "无效指令" ;;
    esac
    read -p "按回车继续..."
done
