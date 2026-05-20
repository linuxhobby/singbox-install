# 输入为 jq -s 合并后的数组：[base.json, protocol1, protocol2, ...]
# 合并 inbounds，并移除 sing-box 不支持的 _comment 字段
. as $all
| $all[0]
| del(._comment)
| .inbounds += ($all[1:] | map(del(._comment)))
