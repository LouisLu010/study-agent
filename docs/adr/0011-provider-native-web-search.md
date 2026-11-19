# 联网搜索只用服务商自带的搜索

联网搜索只接服务商在服务端执行的搜索：Anthropic 的 `web_search`、Gemini 的 Google 搜索接地、OpenAI 兼容协议下的 DeepSeek `deepseek_web_search`、xAI `web_search` 和 OpenAI `web_search_options`（MiniMax 配成 Anthropic 协议时可以直接用 Anthropic 的格式）。模型设置里加"支持联网搜索"开关，其他服务商的模型不能联网。这样用户不用再申请一个搜索服务的 Key，App 也不用在三种协议里各做一套"工具调用 → 执行 → 继续生成"的循环。主力测试模型 `deepseek-flash` 自带偏中文网页的搜索，适合找高考题。代价是各家的请求格式和返回的出处格式都不一样，要分别适配；不在名单里的服务商就用不了联网搜索。

## Considered Options

- App 自己调用 Tavily 或博查，通过工具调用把结果交给模型：所有支持工具调用的模型都能用，表现一致，还能拿到网页原图；但要多一个 Key，三种协议都要实现工具调用循环。以后服务商自带的搜索不够用时再加，作为补充。
