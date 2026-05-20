# 输入为 jq -s 合并后的数组：[base.json, protocol1, protocol2, ...]
. as $all | $all[0] | .inbounds += $all[1:]
