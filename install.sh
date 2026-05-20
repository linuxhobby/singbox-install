#!/bin/bash

BASE_DIR="$(cd "$(dirname "$0")" && pwd)"
CONFIG_TMP="/tmp/sing-box-config.tmp"
CONFIG_FINAL="/usr/local/etc/sing-box/config.json"

source "$BASE_DIR/lib/utils.sh"
check_dependencies

# 注入逻辑封装
process_single() {
    local proto_name=$1
    local proto_file="$BASE_DIR/protocols/${proto_name}.json"
    
    if [[ "$proto_name" == *"reality"* ]]; then
        jq --arg uuid "$(jq -r ".protocols.$proto_name.uuid" "$BASE_DIR/metadata.json")" \
           --arg dest "$(jq -r '.global.dest_reality' "$BASE_DIR/metadata.json")" \
           --arg pk "$(jq -r '.global.reality_public_key' "$BASE_DIR/metadata.json")" \
           --arg sid "$(jq -r '.global.reality_short_id' "$BASE_DIR/metadata.json")" \
           '.users[0].uuid = $uuid | .tls.reality.handshake = $dest | .tls.reality.public_key = $pk | .tls.reality.short_id = $sid' \
           "$proto_file" > "$BASE_DIR/protocols/${proto_name}.tmp"
    else
        jq --arg cred "$(jq -r ".protocols.$proto_name | .uuid // .password" "$BASE_DIR/metadata.json")" \
           --arg domain "$(jq -r '.global.domain' "$BASE_DIR/metadata.json")" \
           '.users[0] |= (if .uuid then .uuid = $cred else .password = $cred end) | .tls.server_name = $domain' \
           "$proto_file" > "$BASE_DIR/protocols/${proto_name}.tmp"
    fi
}

deploy() {
    # 核心合并逻辑
    jq -s -f "$BASE_DIR/lib/processor.jq" "$BASE_DIR/base.json" "$BASE_DIR/protocols/"*.tmp > "$CONFIG_TMP"
    
    # 修改此处：使用绝对路径调用 sing-box
    if /usr/local/bin/sing-box check -c "$CONFIG_TMP"; then
        mv "$CONFIG_TMP" "$CONFIG_FINAL"
        systemctl restart sing-box
        log_info "部署成功。"
    else
        log_error "校验失败，已回滚。"
    fi
    rm -f "$BASE_DIR/protocols/"*.tmp
}

# 菜单入口
echo -e "${BLUE}1) vless_reality_vision 2) vless_reality_xhttp 3) vless_ws_tls 4) vless_grpc_tls 5) vless_xhttp_tls 6) trojan_ws_tls 7) trojan_grpc_tls 8) 全部部署${NC}"
read -p "选择: " choice

case $choice in
    1) process_single "vless_reality_vision"; deploy ;;
    2) process_single "vless_reality_xhttp"; deploy ;;
    3) process_single "vless_ws_tls"; deploy ;;
    4) process_single "vless_grpc_tls"; deploy ;;
    5) process_single "vless_xhttp_tls"; deploy ;;
    6) process_single "trojan_ws_tls"; deploy ;;
    7) process_single "trojan_grpc_tls"; deploy ;;
    8) for f in "$BASE_DIR"/protocols/*.json; do process_single "$(basename "$f" .json)"; done; deploy ;;
    *) log_error "退出"; exit 1 ;;
esac