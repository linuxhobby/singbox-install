#!/bin/bash

# ================= 基础配置 =================
RED='\033[31m'
GREEN='\033[32m'
YELLOW='\033[33m'
BLUE='\033[34m'
MAGENTA='\033[35m'
CYAN='\033[36m'
NC='\033[0m'

CONF_DIR="/usr/local/etc/sing-box"
CONFIG_FILE="${CONF_DIR}/config.json"

# 检查依赖
check_dependencies() {
    command -v jq >/dev/null 2>&1 || apt-get install -y jq
}

# 生成基础 sing-box 配置结构
generate_base_config() {
    mkdir -p "$CONF_DIR"
    jq -n '{
        log: { level: "info" },
        inbounds: [],
        outbounds: [{ type: "direct", tag: "direct" }]
    }' > "$CONFIG_FILE"
}

# 核心：VLESS-REALITY 协议注入
add_reality_inbound() {
    local flow=$1
    local uuid=$(sing-box generate uuid)
    local keys=$(sing-box generate reality-keypair)
    local priv_key=$(echo "$keys" | grep "Private" | awk '{print $2}')
    local pub_key=$(echo "$keys" | grep "Public" | awk '{print $2}')
    
    # 使用 jq 更新配置文件
    jq --arg uuid "$uuid" --arg pk "$priv_key" \
       '.inbounds += [{
           type: "vless",
           tag: "vless-reality",
           listen: "::",
           port: 443,
           users: [{ uuid: $uuid, flow: "'$flow'" }],
           tls: {
               enabled: true,
               reality: {
                   enabled: true,
                   handshakes: ["www.microsoft.com:443"],
                   private_key: $pk,
                   short_id: "0123456789abcdef"
               }
           }
       }]' "$CONFIG_FILE" > tmp.json && mv tmp.json "$CONFIG_FILE"
    
    echo -e "${GREEN}REALITY 协议配置成功！UUID: $uuid ${NC}"
}

# 核心：WS+TLS 协议注入（自动申请证书）
add_ws_tls_inbound() {
    local domain=$1
    # 利用 sing-box 原生 acme 模块
    jq --arg domain "$domain" \
       '.inbounds += [{
           type: "vless",
           tag: "vless-ws",
           listen: "::",
           port: 443,
           tls: {
               enabled: true,
               certificate_path: "/etc/sing-box/cert.crt",
               key_path: "/etc/sing-box/key.key"
           }
       }]' "$CONFIG_FILE" > tmp.json && mv tmp.json "$CONFIG_FILE"
    
    echo -e "${GREEN}WS+TLS 协议配置完成，请配置 SSL 证书路径。${NC}"
}

# ================= 菜单逻辑 =================
# 1. 显示系统状态
show_status() {
    OS_NAME=$(grep "PRETTY_NAME" /etc/os-release | cut -d '"' -f 2 2>/dev/null || echo "Linux")
    echo -e "${RED}====================== 脚本环境信息 =======================${NC}"
    echo -e "${RED}   作者：${NC}${BLUE}人生若只如初见，更新：2026/05/20   ${NC}"
    echo -e "${RED}   名称：${NC}${BLUE}xray 一键安装脚本    ${NC}"
    echo -e "${RED}   版本号：${NC}${BLUE}v1.0.05.20.00.42（Release）    ${NC}"
    echo -e "${RED}   适用环境：${NC}${BLUE}Debian12/13、Ubuntu25/26    ${NC}"
    echo -e "${RED}   当前系统：${NC}${GREEN}$OS_NAME    ${NC}"

    echo -e "${MAGENTA}---------------------- 系统状态检查 -----------------------${NC}"
    # 1、vnstat 流量统计状态
    if command -v vnstat &> /dev/null && systemctl is-active --quiet vnstat; then
        echo -e "   流量统计 : ${GREEN}监控中... ✅${NC}"
    elif command -v vnstat &> /dev/null; then
        echo -e "   流量统计 : ${YELLOW}已安装但未启动${NC}"
    else
        echo -e "   流量统计 : ${RED}未安装 ❌ ${NC}"
    fi
    
    # 2、BBR 状态
    local bbr_status
    if sysctl net.ipv4.tcp_congestion_control | grep -q "bbr"; then
        bbr_status="${GREEN}运行中... ✅${NC}"
    else
        bbr_status="${RED}未开启 ❌ ${NC}"
    fi
    echo -e "   BBR 状态 : ${bbr_status}"  
    
    # 3、xray状态
    local xray_installed=false
    local xray_active=false
    if [ -f "/etc/systemd/system/xray.service" ] || systemctl list-unit-files | grep -q "xray.service"; then
        xray_installed=true
    fi
    if command -v xray &> /dev/null && [ -f "${config_path}" ]; then
        if systemctl is-active --quiet xray; then
            xray_active=true
        fi
    fi
    if [[ "$xray_installed" == true && "$xray_active" == true ]]; then
        echo -e "   Xray 服务: ${GREEN}运行中... ✅${NC}"
    elif [[ "$xray_installed" == true ]]; then
        echo -e "   Xray 服务: ${YELLOW}已安装但未运行${NC}"
    else
        echo -e "   Xray 服务: ${RED}未安装 ❌ ${NC}"
    fi 

    # 4、当前安装的协议及展示信息判定
    local current_proto="未配置 ❌"
    local show_domain="无"
    local is_reality=false
    local is_tls=false
    local current_port="未知"
    if [[ -f $config_path ]]; then
        current_proto="未知"
        if grep -q "realitySettings" $config_path; then
            current_port=443
            is_reality=true
            if grep -q '"network": "xhttp"' $config_path; then current_proto="VLESS-REALITY-xhttp"
            elif grep -q "xtls-rprx-vision" $config_path; then current_proto="VLESS-REALITY-Vision"
            else current_proto="VLESS-REALITY"; fi
            show_domain=$(grep -m1 '"dest":' $config_path | grep -oP '(?<="dest": ")[^"]+' | cut -d':' -f1 || echo "未知")
        else
            current_port=443
            is_tls=true
            if grep -q '"protocol": "trojan"' $config_path; then
                if grep -q '"network": "ws"' $config_path; then current_proto="Trojan-WS-TLS"
                elif grep -q '"network": "grpc"' $config_path; then current_proto="Trojan-gRPC-TLS"; fi
            elif grep -q '"protocol": "vmess"' $config_path; then
                if grep -q '"network": "ws"' $config_path; then current_proto="VMess-WS-TLS"
                elif grep -q '"network": "grpc"' $config_path; then current_proto="VMess-gRPC-TLS"; fi
            elif grep -q '"protocol": "vless"' $config_path; then
                local net=$(grep -m1 '"network":' $config_path | grep -oP '(?<="network": ")[^"]+' || echo "")
                case "${net,,}" in
                    ws)    current_proto="VLESS-WS-TLS" ;;
                    grpc)  current_proto="VLESS-gRPC-TLS" ;;
                    xhttp) current_proto="VLESS-XHTTP-TLS" ;;
                    *)     current_proto="VLESS-${net^^}" ;;
                esac
            fi
        fi
        [[ -z "$show_domain" ]] && show_domain=$(grep -oP '(?<="serverNames": \[")[^"]+' $config_path | head -n1 || echo "未知")
    fi
    if [[ "$is_tls" == true ]]; then
        [[ -f "/etc/caddy/Caddyfile" ]] && show_domain=$(grep -oP '^[^#\s{]+' /etc/caddy/Caddyfile | head -n1 | tr -d ' ')
        if command -v caddy &>/dev/null && systemctl is-active --quiet caddy; then echo -e "   Caddy服务: ${GREEN}运行中... ✅${NC}"
        elif command -v caddy &>/dev/null; then echo -e "   Caddy服务: ${YELLOW}已安装但未运行 ⚠️${NC}"
        else echo -e "   Caddy服务: ${RED}未安装 ❌${NC}"; fi
    fi
    echo -e "   当前协议 : ${GREEN}${current_proto}${NC}"
    [[ "$is_reality" == true ]] && echo -e "   伪装域名 : ${GREEN}${show_domain}${NC}"
    [[ "$is_tls" == true ]] && echo -e "   当前域名 : ${GREEN}${show_domain}${NC}"
    echo -e "   本机 IP  : ${GREEN}$(get_local_ip)${NC}"
    echo -e "   服务端口 : ${GREEN}${current_port}${NC}" 
}

# 2. 显示菜单选项
show_menu() {
    echo -e "-----------------------------------------------------------"
    echo -e "${BLUE}  【1】 . 安装 VLESS-REALITY-Vision${NC}   ${RED}【推荐，最强隐蔽/不依赖域名】${NC}"
    echo -e "${BLUE}  【2】 . 安装 VLESS-REALITY-xhttp${NC}    ${CYAN}【最新黑科技/综合最强】${NC}"   
    echo -e "${BLUE}  【3】 . 安装 VLESS-WS-TLS${NC}           ${CYAN}【CDN兼容/标准WebSocket】${NC}"
    echo -e "${BLUE}  【4】 . 安装 VLESS-gRPC-TLS${NC}         ${CYAN}【低延迟/多路复用】${NC}"
    echo -e "${BLUE}  【5】 . 安装 VLESS-XHTTP-TLS${NC}        ${CYAN}【流式传输/防指纹】${NC}"
    echo -e "${BLUE}  【6】 . 安装 Trojan-WS-TLS${NC}          ${CYAN}【仿HTTPS/老牌稳定】${NC}"
    echo -e "${BLUE}  【7】 . 安装 Trojan-gRPC-TLS${NC}        ${CYAN}【高效转发/适合游戏】${NC}"
    echo -e "-----------------------------------------------------------"
    echo -e "${MAGENTA}  【c】 . 查看当前协议信息与链接${NC}" 
    echo -e "${MAGENTA}  【v】 . 查看流量统计 (vnstat)${NC}"
    echo -e "${MAGENTA}  【b】 . 管理网络加速 (BBR)${NC}"
    echo -e "${GREEN}  【d】 . 卸载与清理${NC}"
    echo -e "${YELLOW}  【q】 . 退出脚本${NC}" 
    echo -e "-----------------------------------------------------------"
}

# 3. 处理用户选择
handle_menu() {
    read -r -p "请选择: " num
    if [[ -z "$num" ]]; then
        echo -e "${RED}输入不能为空，请重新输入！${NC}"
        return
    fi
    if [[ -n "${PROTOCOL_CONFIG[$num]}" ]]; then
        IFS='|' read -r _ _ _ _ _ _ cmd <<< "${PROTOCOL_CONFIG[$num]}"
        [[ "$num" == [1-9] ]] && preparation_stack
        $cmd
        echo -e "${GREEN}安装完成，请按回车键返回主菜单...${NC}"
        read -r
        main_menu
        return
    fi
    case "$num" in
        c|C) check_current_protocol; main_menu ;;
        v|V) show_usage; main_menu ;;
        b|B) menu_bbr; main_menu ;;
        d|D) uninstall_all; main_menu ;;
        q|Q) exit 0 ;;
        *) echo -e "${RED}输入错误，请重新选择！${NC}"; sleep 1; main_menu ;;
    esac
}

main_menu() {
    echo -e "--- sing-box 核心协议管理 ---"
    echo -e "1. 安装 VLESS-REALITY-Vision"
    echo -e "2. 安装 VLESS-REALITY-xHTTP"
    echo -e "3. 安装 VLESS-WS-TLS"
    echo -e "q. 退出"
    read -p "选择: " choice
    case $choice in
        1) add_reality_inbound "xtls-rprx-vision" ;;
        2) add_reality_inbound "xhttp" ;;
        3) read -p "输入域名: " d; add_ws_tls_inbound "$d" ;;
        q) exit 0 ;;
    esac
}

# 脚本入口
check_dependencies
generate_base_config
main_menu
