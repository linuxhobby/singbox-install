# 接收 base.json (作为 .[0]) 和所有协议片段 (作为 .[1:])
# 合并至 base.json 的 inbounds 数组中
.[0] | .inbounds += [.[1:] | .[]]