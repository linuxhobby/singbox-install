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
        # 增加对 XHTTP 协议的特殊判断
        if [[ "$proto_name" == *"xhttp"* ]]; then
            jq --arg cred "$(jq -r ".protocols.$proto_name | .uuid // .password" "$BASE_DIR/metadata.json")" \
               --arg domain "$(jq -r '.global.domain' "$BASE_DIR/metadata.json")" \
               --arg path "$(jq -r '.global.xhttp_path' "$BASE_DIR/metadata.json")" \
               '.users[0] |= (if .uuid then .uuid = $cred else .password = $cred end) | .transport.path = $path | .tls.server_name = $domain' \
               "$proto_file" > "$BASE_DIR/protocols/${proto_name}.tmp"
        else
            # 原有的通用 TLS 分支
            jq --arg cred "$(jq -r ".protocols.$proto_name | .uuid // .password" "$BASE_DIR/metadata.json")" \
               --arg domain "$(jq -r '.global.domain' "$BASE_DIR/metadata.json")" \
               '.users[0] |= (if .uuid then .uuid = $cred else .password = $cred end) | .tls.server_name = $domain' \
               "$proto_file" > "$BASE_DIR/protocols/${proto_name}.tmp"
        fi
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

# 在 process_single 中生成特定文件后：
# 执行合并逻辑时，建议改为只针对当前的 tmp 文件（或者确保 process_single 逻辑是单次任务）
}

# 菜单入口
show_menu() {
    clear
    echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "  ${YELLOW}SING-BOX 协议管理器 v1.0 | 系统工具控制台${NC}"
    echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "  ${GREEN}>> 协议部署模块${NC}"
    echo -e "  [1] VLESS-REALITY-Vision"
    echo -e "  [2] VLESS-REALITY-XHTTP"
    echo -e "  [3] VLESS-WS-TLS"
    echo -e "  [4] VLESS-GRPC-TLS"
    echo -e "  [5] VLESS-XHTTP-TLS"
    echo -e "  [6] TROJAN-WS-TLS"
    echo -e "  [7] TROJAN-GRPC-TLS"
    echo -e "  ${GREEN}>> 系统维护模块${NC}"
    echo -e "  [c] 批量部署全部协议"
    echo -e "  [v] 查看流量统计 (vnstat)"
    echo -e "  [b] 启用 TCP BBR 加速"
    echo -e "  [q] 退出控制台"
    echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
}


# 进入循环，实现菜单的可持续交互
while true; do
    show_menu
    read -p "指令: " choice
    case $choice in
        1) process_single "vless_reality_vision"; deploy ;;
        2) process_single "vless_reality_xhttp"; deploy ;;
        3) process_single "vless_ws_tls"; deploy ;;
        4) process_single "vless_grpc_tls"; deploy ;;
        5) process_single "vless_xhttp_tls"; deploy ;;
        6) process_single "trojan_ws_tls"; deploy ;;
        7) process_single "trojan_grpc_tls"; deploy ;;
        c) for f in "$BASE_DIR"/protocols/*.json; do process_single "$(basename "$f" .json)"; done; deploy ;;
        v) show_traffic ;;
        b) enable_bbr ;;
        q) exit 0 ;;
        *) echo "无效指令" ;;
    esac
    read -p "回车继续..."
done