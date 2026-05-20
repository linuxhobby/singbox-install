#!/bin/bash

BASE_DIR="$(cd "$(dirname "$0")" && pwd)"
CONFIG_TMP="/tmp/sing-box-config.tmp"
CONFIG_FINAL="/usr/local/etc/sing-box/config.json"
METADATA="$BASE_DIR/metadata.json"

source "$BASE_DIR/lib/utils.sh"
check_dependencies

# ==================== 改进后的 process_single ====================
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

# ==================== 改进后的 deploy ====================
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

# ==================== 客户端链接生成 ====================
generate_client_links() {
    log_info "生成客户端链接..."
    # 示例 for VLESS Reality
    uuid=$(jq -r '.protocols.vless_reality_vision.uuid' "$METADATA")
    public_key=$(jq -r '.global.reality_public_key' "$METADATA")
    dest=$(jq -r '.global.dest_reality' "$METADATA")
    
    link="vless://$uuid@your-server-ip:10001?security=reality&fp=chrome&pbk=$public_key&sni=www.google.com&type=tcp&flow=xtls-rprx-vision#VLESS-REALITY-Vision"
    echo -e "\n📱 客户端链接："
    echo "$link"
    
    if command -v qrencode &> /dev/null; then
        echo "$link" | qrencode -t ANSI
    fi
}

# ==================== 初始化向导 ====================
init_config() {
    if [[ ! -f "$METADATA" ]] || [[ "$(jq -r '.global.domain' "$METADATA")" == "yourdomain.com" ]]; then
        log_info "首次运行，进入初始化配置..."
        # ... (keep previous init logic)
    fi
}

# 菜单和主循环 (保持类似，添加 [i] 初始化)
show_menu() {
    clear
    echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "  ${YELLOW}SING-BOX 协议管理器 v1.3${NC}"
    # ... 省略完整菜单，实际使用时补全
}

init_config

while true; do
    show_menu
    read -p "请输入指令: " choice
    case $choice in
        1) process_single "vless_reality_vision"; deploy ;;
        2) process_single "vless_reality_xhttp"; deploy ;;
        # 添加其他
        i) init_config ;;
        q) exit 0 ;;
        *) echo "无效" ;;
    esac
    read -p "按回车继续..."
done