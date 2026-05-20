#!/bin/bash

# 终端颜色定义
export RED='\033[31m'
export GREEN='\033[32m'
export YELLOW='\033[33m'
export BLUE='\033[34m'
export NC='\033[0m' # No Color

# 格式化输出函数
log_info() {
    echo -e "${GREEN}[INFO]${NC} $1"
}

log_warn() {
    echo -e "${YELLOW}[WARN]${NC} $1"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

# 安装 Sing-box 的函数
install_singbox() {
    log_info "正在检测并安装 Sing-box..."
    
    # 使用官方脚本进行安装
    bash <(curl -fsSL https://sing-box.app/install.sh)
    
    if [ $? -eq 0 ]; then
        log_info "Sing-box 安装成功。"
        # 确保权限
        chmod +x /usr/local/bin/sing-box
    else
        log_error "Sing-box 安装失败，请检查网络或权限。"
        exit 1
    fi
}

# 流量统计函数
show_traffic() {
    if ! command -v vnstat &> /dev/null; then
        log_info "正在安装 vnstat..."
        apt-get update && apt-get install -y vnstat
        systemctl enable --now vnstat
    fi
    log_info "当前流量统计："
    vnstat -i eth0 -h 24 # 显示 eth0 接口的 24 小时流量
}

# 开启 BBR 函数
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

# 检查依赖项
check_dependencies() {
    # 检查 jq
    if ! command -v jq &> /dev/null; then
        log_error "缺少依赖: jq，正在尝试安装..."
        apt-get update && apt-get install -y jq
    fi

    # 检查 sing-box，未找到则调用上面的安装函数
    if ! command -v sing-box &> /dev/null; then
        log_warn "未发现 Sing-box，准备安装..."
        install_singbox
    else
        log_info "依赖检查通过。"
    fi
}

# 校验 JSON 有效性
validate_json() {
    if ! jq empty "$1" > /dev/null 2>&1; then
        log_error "文件 $1 不是有效的 JSON 格式。"
        return 1
    fi
    return 0
}
