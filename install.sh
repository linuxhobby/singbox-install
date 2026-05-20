#!/bin/bash

# 定义相对路径
BASE_DIR="$(cd "$(dirname "$0")" && pwd)"
CONFIG_TMP="/tmp/sing-box-config.tmp"
CONFIG_FINAL="/usr/local/etc/sing-box/config.json"

# 1. 变量加载与注入
for proto_file in "$BASE_DIR"/protocols/*.json; do
    proto_name=$(basename "$proto_file" .json)
    
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
done

# 2. 合并配置
jq -s '.[0].inbounds += .[1:] | .[0]' \
   "$BASE_DIR/base.json" \
   "$BASE_DIR/protocols/"*.tmp > "$CONFIG_TMP"

# 3. 校验并部署
if /usr/local/bin/sing-box check -c "$CONFIG_TMP"; then
    mv "$CONFIG_TMP" "$CONFIG_FINAL"
    systemctl restart sing-box
    echo "配置更新成功。"
else
    echo "配置校验失败，已回滚。"
    rm -f "$BASE_DIR/protocols/"*.tmp
    exit 1
fi

# 4. 清理临时文件
rm -f "$BASE_DIR/protocols/"*.tmp