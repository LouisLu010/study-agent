# Study Agent

一个运行在 iPhone 和 iPad 上的大模型聊天客户端，目标是让学习类对话的显示效果达到 ChatGPT 官方客户端的水平，包括公式、化学式和可交互的坐标图。

- 术语：[GLOSSARY.md](./GLOSSARY.md)
- 架构决策：[docs/adr/](./docs/adr/)

## 第一版范围

- **平台**：iOS / iPadOS 18+，纯 SwiftUI。iPad 用分栏布局。不适配 Mac。
- **模型接入**：用户自带 API Key，不建后端。原生支持 OpenAI 兼容协议（Chat Completions）、Anthropic Messages、Google Gemini 三种协议。可以添加多个服务商和模型，设一个默认模型，每个会话可以单独切换模型。
- **渲染**：Markdown、表格、代码高亮、LaTeX 公式（行内和块级）、mhchem 化学式、可缩放拖动的二维坐标图。
- **输入**：文字和图片。图片发送前压缩到长边不超过 2048 像素。
- **生成过程**：流式输出；公式未闭合时先显示灰色源码；推理模型的思考过程折叠显示；可以随时停止生成。
- **消息操作**：复制整条消息、复制单个公式的 LaTeX 源码、重新生成、编辑用户消息后重发。不保留多个版本。
- **提示词**：App 内置格式规则，加上一段全局的用户提示词。
- **数据**：只存在本机，暂不做 iCloud 同步。

## 构建与安装

本仓库不包含 `.xcodeproj`。GitHub Actions 会用 XcodeGen 从 `project.yml` 生成工程，然后运行测试、编译 App，并打包一个未签名的 `.ipa`。下载这个 `.ipa` 后，在 Windows 上用 Sideloadly 或 AltStore 配合免费 Apple ID 签名安装，每 7 天需要重签一次。

1. 打开仓库的 Actions 页面，进入最新一次成功的 CI 运行，在页面底部下载 `StudyAgent-unsigned-ipa`，解压得到 `StudyAgent-unsigned.ipa`。
2. 用 Sideloadly 把它装到 iPhone 或 iPad 上，登录你的 Apple ID。
3. 在设备的"设置 → 通用 → VPN 与设备管理"里信任你的 Apple ID，然后打开 App。

## 第一次使用

1. 点左上角的齿轮打开设置，点"添加服务商"，选择协议，填写 API 地址和 API Key。
2. 在服务商页面点"添加模型"，填写模型 ID（必须和服务商文档里写的一样）。如果模型能看图，就打开"支持图片输入"。第一个添加的模型会自动成为默认模型。
3. 回到会话列表，点右上角新建会话，就可以开始提问了。

API Key 只存在设备的钥匙串里，App 直接请求服务商的接口，中间没有任何服务器。

## 目录

- `App/`：SwiftUI 界面、WebView 渲染、图片处理
- `StudyKit/`：不依赖界面的代码（数据模型、三种协议、SSE 解析、内置提示词）和测试
- `Renderer/`：WebView 里运行的渲染器（Markdown、公式、化学式、代码、坐标图）和第三方库
- `RendererTests/`：渲染器的 Node 测试，运行方法是 `node --test RendererTests/*.test.js`

## 里程碑

1. **M1 骨架**：工程结构、CI、服务商和模型配置、会话列表、OpenAI 兼容协议的流式纯文本聊天。
2. **M2 渲染**：WebView + markdown-it + KaTeX + mhchem + 代码高亮。
3. **M3 坐标图**：```` ```graph ```` 代码块格式、内置提示词、JSXGraph 绘制。
4. **M4 补全协议**：Anthropic 和 Gemini 协议、思考过程、思考强度设置。
5. **M5 图片和细节**：图片输入、自动生成会话标题、搜索、重新生成和编辑后重发、错误提示和重试。
