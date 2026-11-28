---
inclusion: always
---

# 格物项目概览

给新开的 agent 会话看的速查，读完这份就能开始干活，不用通读整个仓库。细节以代码为准；这份文档和代码不一致时，改这份文档。

## 是什么

iPhone / iPad 上的大模型学习聊天 App，SwiftUI，界面全是中文。用户自带 API Key 直连服务商，没有后端（ADR-0001），数据只存本机（ADR-0004）。使用 XcodeGen 生成工程，在可用的 Mac 上构建和测试；GitHub Actions 也会编译并打包（ADR-0005 记录的是早期没有 Mac 时的取舍）。

## 先读哪些文件

- `GLOSSARY.md`：术语表。界面文字、代码注释、提交说明都用这里的词，`_Avoid_` 里的词不要用。
- `README.md`：每一版一节"第N版范围"，下面是版本计划、"不做"列表、阶段和"实现"记录。要知道某个功能为什么这样做，先在这里搜。
- `docs/adr/`：架构决定，0001 到 0014。改动碰到这些决定时先读对应的 ADR。

## 目录

| 位置 | 内容 |
|---|---|
| `App/` | SwiftUI 界面。`Views/`（聊天、输入框、会话列表、`Settings/`）、`Study/`（今天、错题本、复习、收藏、统计）、`Library/`（资料、汇编、后台保活）、`Onboarding/`、`Rendering/`（WebView 和导出）、`Images/`（拍照、PDF、手写）、`Design/`（`Theme`、`OrbEmptyState`、`LibraryRow`） |
| `App/GenerationCenter.swift` | 发消息、重新生成、继续生成、编辑后重发、自动起标题 |
| `App/AppSettings.swift` | 所有 UserDefaults 键（`AppSettingsKey`） |
| `StudyKit/` | 不依赖界面的 Swift 包：`Persistence/`（SwiftData 模型）、`Providers/`（OpenAI 兼容、Anthropic、Gemini 三种协议，服务商预设）、`Chat/`（系统提示词、版本、复习节奏、统计、联网搜索、工具循环）、`Compilation/`（汇编）、`Streaming/`（SSE）、`Prompts/`（内置提示词）、`Pricing/prices.json` |
| `Renderer/` | WebView 里的渲染器（Markdown、KaTeX、mhchem、组件、模拟），纯 JS |
| `RendererTests/` | 渲染器的 Node 测试 |
| `tools/eval/` | 用真实模型测试提示词和组件格式 |
| `promo/`、`docs/promo/` | Remotion 宣传片，和 App 无关 |

## 关键机制

- **系统提示词**：`StudyKit/Sources/StudyKit/Chat/SystemPrompt.swift` 的 `compose`，按顺序拼接 `Prompts/base.md`（格式规则）、`Prompts/components.md`（组件规则，简洁模式下不加）、人格（`Prompts/personas.json`，第九版）、用户提示词、会话提示词。聊天在 `GenerationCenter.startReply` 里每次请求重新拼。资料和汇编用自己的提示词，不带用户提示词。顺序有测试：`ReplyVersionsTests`。
- **组件**：模型输出一个代码块，语言名是组件种类（`graph`、`geometry`、`chart`、`quiz`、`steps`、模拟），内容是 JSON，由 `Renderer/` 绘制（ADR-0002、0003、0006、0010）。组件状态存在消息里，不发给模型。
- **数据**：SwiftData，没有 `VersionedSchema`，靠轻量迁移。规则：每个属性可选或有默认值，不加唯一约束，关系都是可选的（`Models.swift` 开头）。API Key 存钥匙串（`KeychainStore`）。设置存 UserDefaults，界面里用 `@AppStorage`。
- **错题、收藏、资料都是独立副本**，删会话不影响它们（ADR-0009）。
- **知识卡和关系图**（第十版）：资料由 `ConceptCard` 组成，关联是单独的 `ConceptLink` 表、用 ID 指向两头（ADR-0015）。整理提示词在 `Prompts/cards.md`，解析在 `ConceptCardWriter`，读写在 `App/Library/ConceptCardStore.swift`，弹窗 `ConceptCardPopup`，关系图 `ConceptMapView` + StudyKit 的 `ConceptMapLayout`。
- **学习助手**（第十一版）：`Conversation.isStudyAssistant` 标记普通会话，侧栏入口 `StudyAssistantHomeView`。`StudyAssistantTools` 提供只读查找和分段读取，`StudyRecordStore` 统一定位会话、错题、知识卡、汇编和原题，`StudyAssistantToolbox` 分页检索，`StudyAssistantReply` 通过工具循环写入普通消息。`Message.studyReferencesJSON` 保存真实本地引用，回答版本同步保存；`StudyReferenceSheet` 打开原记录。首版不联网、不修改原记录、不读取记录中的图片。后续方向见 `docs/future-goals.md`。
- **联网搜索**只用服务商自带的（ADR-0011）；汇编用 App 内置的工具（ADR-0014）。
- **后台运行**：`App/Library/BackgroundKeeper.swift`，聊天和汇编共用（ADR-0012）。

## 构建和测试

- CI（`.github/workflows/ci.yml`，macOS）：`swift test --package-path StudyKit`、`node --test RendererTests/*.test.js`、`xcodegen generate` 后编译模拟器和真机版，打包未签名 ipa。
- 先检查实际环境；当前工作区可在 macOS 上运行 `swift test --package-path StudyKit` 和 iOS Simulator 的 `xcodebuild test`。Linux 缺少 SwiftData，不能在那里验证整个包。不要因早期环境记录而跳过当前可运行的构建与测试。
- 改了 `Prompts/` 或组件格式：用 `tools/eval/run.js` 跑真实模型（Key 只从环境变量 `STUDY_TEST_API_KEY` 读，绝不写进仓库），用法见 README"用真实模型测试组件"。
- 版本号在 `project.yml` 的 `MARKETING_VERSION`。

## 工作习惯

- 每一版先在 README 写"第N版范围"（分组、不做、阶段），定下来再写代码；做完补"实现"一段，写清做了什么、还要在真机上检查什么。
- 一个版本一个 PR，每个阶段一个提交。提交说明用 `feat(v8): …`、`fix(promo): …`、`docs(v8): …` 这种格式。
- 新术语定下来就写进 `GLOSSARY.md`；难以撤回、有真实取舍、以后的人会奇怪的决定才写 ADR。
- 代码注释和文档用中文。
