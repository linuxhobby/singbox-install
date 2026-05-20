# 接收 base.json 作为输入流
# 将后续传入的协议片段对象合并至 inbounds 数组中
.inbounds += [.[1:] | .[]]