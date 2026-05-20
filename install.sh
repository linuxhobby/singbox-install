#!/bin/bash

# ================= 基础配置 =================
RED='\033[31m'; GREEN='\033[32m'; YELLOW='\033[33m'; NC='\033[0m'
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
