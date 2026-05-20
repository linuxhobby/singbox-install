#!/bin/bash

BASE_DIR="$(cd "$(dirname "$0")" && pwd)"
CONFIG_TMP="/tmp/sing-box-config.tmp"
CONFIG_FINAL=""
SINGBOX_BIN=""

# 7 种协议（顺序与菜单一致）
PROTOCOLS=(
    vless_reality_vision
    vless_reality_xhttp
    vless_ws_tls
    vless_grpc_tls
    vless_xhttp_tls
    trojan_ws_tls
    trojan_grpc_tls
)

PROTOCOL_LABELS=(
    "VLESS-REALITY-Vision"
    "VLESS-REALITY-XHTTP"
    "VLESS-WS-TLS"
    "VLESS-GRPC-TLS"
    "VLESS-XHTTP-TLS"
    "TROJAN-WS-TLS"
    "TROJAN-GRPC-TLS"
)

source "$BASE_DIR/lib/utils.sh"
check_dependencies
resolve_config_final
ensure_config_dir

# 将协议模板注入 metadata 参数，生成 .tmp
process_single() {
    local proto_name=$1
    local proto_file="$BASE_DIR/protocols/${proto_name}.json"
    local out_file="$BASE_DIR/protocols/${proto_name}.tmp"
    local meta="$BASE_DIR/metadata.json"

    if [[ ! -f "$proto_file" ]]; then
        log_error "协议模板不存在: $proto_file"
        return 1
    fi
    if ! validate_json "$meta"; then
        return 1
    fi

    local listen_port
    listen_port=$(jq -r ".protocols.${proto_name}.port // 443" "$meta")
    [[ "$listen_port" == "null" || -z "$listen_port" ]] && listen_port=443

    if [[ "$proto_name" == *"reality"* ]]; then
        local dest hs_server hs_port
        dest=$(jq -r '.global.dest_reality' "$meta")
        if [[ "$dest" == *:* ]]; then
            hs_port="${dest##*:}"
            hs_server="${dest%:*}"
        else
            hs_server="$dest"
            hs_port=443
        fi
        jq --arg uuid "$(jq -r ".protocols.${proto_name}.uuid" "$meta")" \
           --arg srv "$hs_server" \
           --argjson hs_port "$hs_port" \
           --argjson listen_port "$listen_port" \
           --arg sk "$(jq -r '.global.reality_private_key' "$meta")" \
           --arg sid "$(jq -r '.global.reality_short_id' "$meta")" \
           '.users[0].uuid = $uuid
            | .listen_port = $listen_port
            | .tls.reality.handshake = {server: $srv, server_port: $hs_port}
            | .tls.reality.private_key = $sk
            | .tls.reality.short_id = [$sid]' \
           "$proto_file" > "$out_file"
    elif [[ "$proto_name" == *"xhttp"* ]]; then
        jq --arg cred "$(jq -r ".protocols.${proto_name} | .uuid // .password" "$meta")" \
           --arg domain "$(jq -r '.global.domain' "$meta")" \
           --arg path "$(jq -r '.global.xhttp_path' "$meta")" \
           --argjson listen_port "$listen_port" \
           '.users[0] |= (if .uuid then .uuid = $cred else .password = $cred end)
            | .listen_port = $listen_port
            | .transport.path = $path
            | .tls.server_name = $domain' \
           "$proto_file" > "$out_file"
    elif [[ "$proto_name" == *"_ws_"* ]]; then
        local ws_path
        if [[ "$proto_name" == trojan_* ]]; then
            ws_path=$(jq -r '.global.trojan_ws_path' "$meta")
        else
            ws_path=$(jq -r '.global.ws_path' "$meta")
        fi
        jq --arg cred "$(jq -r ".protocols.${proto_name} | .uuid // .password" "$meta")" \
           --arg domain "$(jq -r '.global.domain' "$meta")" \
           --arg wspath "$ws_path" \
           --argjson listen_port "$listen_port" \
           '.users[0] |= (if .uuid then .uuid = $cred else .password = $cred end)
            | .listen_port = $listen_port
            | .transport.path = $wspath
            | .tls.server_name = $domain' \
           "$proto_file" > "$out_file"
    else
        jq --arg cred "$(jq -r ".protocols.${proto_name} | .uuid // .password" "$meta")" \
           --arg domain "$(jq -r '.global.domain' "$meta")" \
           --argjson listen_port "$listen_port" \
           '.users[0] |= (if .uuid then .uuid = $cred else .password = $cred end)
            | .listen_port = $listen_port
            | .tls.server_name = $domain' \
           "$proto_file" > "$out_file"
    fi

    if ! validate_json "$out_file"; then
        rm -f "$out_file"
        return 1
    fi
    return 0
}

# 合并并部署；可选仅部署指定协议
deploy() {
    local only_proto="${1:-}"
    local -a tmp_files=()
    local backup=""

    if [[ -n "$only_proto" ]]; then
        local single_tmp="$BASE_DIR/protocols/${only_proto}.tmp"
        if [[ ! -f "$single_tmp" ]]; then
            log_error "未找到协议临时配置: ${only_proto}.tmp，请先执行安装。"
            return 1
        fi
        tmp_files=("$single_tmp")
    else
        shopt -s nullglob
        tmp_files=("$BASE_DIR"/protocols/*.tmp)
        shopt -u nullglob
        if [[ ${#tmp_files[@]} -eq 0 ]]; then
            log_error "没有可部署的协议配置，请先安装协议。"
            return 1
        fi
    fi

    if [[ -f "$CONFIG_FINAL" ]]; then
        backup="${CONFIG_FINAL}.bak.$$"
        cp "$CONFIG_FINAL" "$backup"
    fi

    if ! jq -s -f "$BASE_DIR/lib/processor.jq" "$BASE_DIR/base.json" "${tmp_files[@]}" > "$CONFIG_TMP"; then
        log_error "配置合并失败。"
        [[ -n "$backup" ]] && mv "$backup" "$CONFIG_FINAL"
        return 1
    fi

    if ! ensure_singbox; then
        log_error "sing-box 未安装，无法校验配置。"
        [[ -n "$backup" ]] && mv "$backup" "$CONFIG_FINAL"
        return 1
    fi

    if "$SINGBOX_BIN" check -c "$CONFIG_TMP" 2>&1; then
        mv "$CONFIG_TMP" "$CONFIG_FINAL"
        sync_stale_config_paths
        systemctl enable sing-box 2>/dev/null
        systemctl daemon-reload 2>/dev/null
        systemctl restart sing-box
        sleep 1
        rm -f "$backup"
        rm -f "$BASE_DIR/protocols/"*.tmp
        if verify_deploy_result "$only_proto"; then
            local deploy_port=""
            [[ -n "$only_proto" ]] && deploy_port=$(get_deployed_port "$only_proto")
            open_config_ports
            if check_service_health "$deploy_port"; then
                log_info "部署成功，服务已加载: ${CONFIG_FINAL}"
                log_warn "若仍无法连接，请在云服务商控制台安全组放行对应 TCP 端口。"
                return 0
            fi
            log_warn "配置已写入但服务/端口检查未通过，请根据上方日志排查。"
            return 1
        fi
        log_error "配置已写入但验证未通过，请检查 systemd 使用的配置路径。"
        return 1
    fi

    log_error "配置校验失败，已回滚。详情见上方 sing-box check 输出。"
    rm -f "$CONFIG_TMP"
    if [[ -n "$backup" ]]; then
        mv "$backup" "$CONFIG_FINAL"
        systemctl restart sing-box 2>/dev/null
    fi
    return 1
}

# 安装单个协议：生成配置 → 部署 → 展示节点链接
install_protocol() {
    local proto_name=$1
    local idx label

    for i in "${!PROTOCOLS[@]}"; do
        if [[ "${PROTOCOLS[$i]}" == "$proto_name" ]]; then
            idx=$i
            label="${PROTOCOL_LABELS[$i]}"
            break
        fi
    done

    log_info "正在安装 ${label:-$proto_name} ..."

    if ! ensure_metadata "$proto_name"; then
        return 1
    fi

    rm -f "$BASE_DIR/protocols/"*.tmp

    if ! process_single "$proto_name"; then
        return 1
    fi
    if ! deploy "$proto_name"; then
        return 1
    fi

    show_protocol_info "$proto_name" "${label:-}"
}

# 7 种协议独立安装入口
install_vless_reality_vision() { install_protocol vless_reality_vision; }
install_vless_reality_xhttp()  { install_protocol vless_reality_xhttp; }
install_vless_ws_tls()         { install_protocol vless_ws_tls; }
install_vless_grpc_tls()       { install_protocol vless_grpc_tls; }
install_vless_xhttp_tls()      { install_protocol vless_xhttp_tls; }
install_trojan_ws_tls()        { install_protocol trojan_ws_tls; }
install_trojan_grpc_tls()      { install_protocol trojan_grpc_tls; }

show_menu() {
    clear
    echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "  ${YELLOW}SING-BOX 协议管理器 v1.1 | 系统工具控制台${NC}"
    echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    show_system_status
    echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "  ${GREEN}>> 协议安装模块（7 种）${NC}"
    echo -e "  [1] VLESS-REALITY-Vision"
    echo -e "  [2] VLESS-REALITY-XHTTP"
    echo -e "  [3] VLESS-WS-TLS"
    echo -e "  [4] VLESS-GRPC-TLS"
    echo -e "  [5] VLESS-XHTTP-TLS"
    echo -e "  [6] TROJAN-WS-TLS"
    echo -e "  [7] TROJAN-GRPC-TLS"
    echo -e "  ${GREEN}>> 系统维护模块${NC}"
    echo -e "  [c] 查看当前协议信息与链接"
    echo -e "  [i] 重新运行配置向导 (安装协议时会自动检测)"
    echo -e "  [v] 查看流量统计 (vnstat)"
    echo -e "  [b] 启用 TCP BBR 加速"
    echo -e "  [d] 卸载 sing-box"
    echo -e "  [q] 退出控制台"
    echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
}

while true; do
    show_menu
    read -rp "指令: " choice
    case $choice in
        1) install_vless_reality_vision ;;
        2) install_vless_reality_xhttp ;;
        3) install_vless_ws_tls ;;
        4) install_vless_grpc_tls ;;
        5) install_vless_xhttp_tls ;;
        6) install_trojan_ws_tls ;;
        7) install_trojan_grpc_tls ;;
        c) view_installed_protocols ;;
        i) setup_metadata ;;
        v) show_traffic ;;
        b) enable_bbr ;;
        d) uninstall_singbox ;;
        q) exit 0 ;;
        *) echo "无效指令" ;;
    esac
    read -rp "回车继续..."
done
