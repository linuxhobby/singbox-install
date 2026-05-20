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

# 检查依赖项
check_dependencies() {
    # 移除 sing-box 的检测，直接手动定义，防止路径找不到
    if ! command -v jq &> /dev/null; then
        log_error "缺少依赖: jq，请先安装。"
        exit 1
    fi
    
    # 手动指定 sing-box 二进制路径（请确保路径正确，若在 /usr/local/bin/sing-box 请保持不变）
    SINGBOX_PATH="/usr/local/bin/sing-box"
    if [ ! -f "$SINGBOX_PATH" ]; then
        log_error "未在 $SINGBOX_PATH 找到 sing-box 程序。"
        exit 1
    fi
    log_info "依赖检查通过。"
}

# 校验 JSON 有效性
validate_json() {
    if ! jq empty "$1" > /dev/null 2>&1; then
        log_error "文件 $1 不是有效的 JSON 格式。"
        return 1
    fi
    return 0
}