# 格物宣传片

一部 75 秒的横屏宣传片，整部用 [Remotion](https://www.remotion.dev/) 按帧生成，配乐也由代码合成。工程在 [`promo/`](../../promo/)。

**1.0 版**（在 0.8.0 那一版的基础上）：开场和片尾换成 App 图标，左上角一直有图标、"格物"和"1.0"；左边一栏的字幕从一句大标题改成小标题、大标题、一句说明和三个要点，底部标第几段；新增"人格"一段和"还有这些"功能一览；配乐和音效直接合成进片子。

## 定下来的事

| | 决定 |
|---|---|
| 观众 | 第一次听说格物的人：同学、朋友和 B 站上的高中生，看完想试试；成片也放进仓库 README |
| 版本 | 1.0 |
| 画幅和片长 | 横屏 16:9，1920×1080，30 fps，75.5 秒 |
| 外观 | 深色模式，iOS 26（玻璃输入框、滚动边缘模糊） |
| 设备 | iPad 横屏为主，放在画面右边约 62% 宽；"今天"那个镜头换成 iPhone。设备框是自己画的圆角矩形，不用 Apple 的产品图 |
| 原生界面 | 不录屏。照 SwiftUI 代码用 React 还原，样式常量抄自 `App/Design/Theme.swift`，对照 `reference/` 里的真机截图 |
| 组件 | 用 App 的渲染器（`Renderer/`）在 iframe 里直接画，组件 JSON 是手写的 |
| 图标和小球 | 开场、片尾和左上角用 App 图标（`prepare-renderer` 从 `App/Assets.xcassets` 复制）。小球是 Thinking Orbs 0.1.2 的原版，只表示模型在想，开场发送以后出现 |
| 字幕 | 左边一栏：小标题、大标题、一句说明、三个要点，底部"01 ··· 07"标第几段 |
| 声音 | 不配旁白。配乐是 `scripts/make-music.mjs` 合成的纯音乐（120 BPM，F–G–Em–Am 电钢琴琶音、铺底、贝斯、轻鼓，片尾落在 C 大调上），音效按 `timeline.json` 的 cues 混进去。没有用任何现成的音乐或采样，可以随片子公开 |
| 字体和图标 | 苹果系统字体（苹方、SF Pro）和 SF Symbols，只在 macOS 上渲染，见下面"字体和图标" |
| 片尾 | 图标、"格物"、"格物致知"、"1.0 正式版"、支持的设备、免费开源、去 Releases 下载、仓库地址，最后一行"界面为按 App 还原的演示画面，示例内容为预设 · 配乐由代码合成" |

## 分镜

镜头切换对齐 120 BPM（每 0.5 秒一拍）。帧号和字幕的准数在 [`promo/src/timeline.json`](../../promo/src/timeline.json)。

| 时间 | 段落 | 画面 | 字幕 |
|---|---|---|---|
| 0:00–0:06 | 开场 | 图标、"格物"、"为学习做的大模型 App"、"1.0 正式版"依次出现；图标让位给小球，输入框里打出"摆长变长，单摆会摆得更慢吗？"，按下发送 | — |
| 0:06–0:12.5 | 单摆 | 镜头贴着模拟卡片。拖摆长 1 m → 2.5 m，松手后摆起来，能量柱实时变化 | 摆长、周期、能量，直接看得见 |
| 0:12.5–0:19 | 坐标图 | 拖参数 a 0.5 → 2.2，抛物线平移，零点和极小值跟着走，读数实时变 | 参数一拖，图像跟着变 |
| 0:19–0:25 | 化学平衡 | 点 2×，A ⇌ B 先达到平衡，中途加入 A，走到新的平衡 | 加入反应物，平衡往哪边移 |
| 0:25–0:32.5 | 人格 | 点会话标题，菜单里选"启发式"；回答不直接给根，一步步提问；下面出现"讲简单点""换个思路""出道练习题" | 同一道题，换一种讲法 |
| 0:32.5–0:38.5 | 测验 | 第 1 题选对，第 2 题选错，出现"已加入错题本" | 做错的题，自动进错题本 |
| 0:38.5–0:48.5 | 错题和复习 | 错题本插入新的一行 → 开始复习 → 答对升档 → iPhone 上的"今天"，连续学习天数 11 → 12 | 隔 1、3、7、14、30 天，再考你一次 |
| 0:48.5–1:00.5 | 汇编 | 新建汇编 → 9 份试卷 → 调用记录往上滚 → A4 PDF 翻到第 2 页 | 一句话，汇编高考原题 |
| 1:00.5–1:07.5 | 还有这些 | 8 张功能卡片依次出现，下面一行支持的服务商 | — |
| 1:07.5–1:15.5 | 片尾 | 见上表 | — |

几何图、图表、分步讲解、联网搜索的出处卡片这次不拍。人格那段的回答按 deepseek-flash 在"启发式"人格下的真实回答缩短。

## 转场

- **段与段之间**：每段往后多演 15 帧（半拍），和下一段交叠。下一段铺着黑底，在上面从透明淡到不透明，所以中间不闪黑，也不会在淡完那一帧突然跳一下。
- **同一个机位**：交互式回答的每段都从整台 iPad 开始、以整台 iPad 结束，交叠时两段的 iPad 在同一个位置，看起来只是侧栏换了选中的会话、屏幕换了内容。淡完以后才推近到组件卡片，推近时聊天同时往上滚，像手指把卡片推上来。
- **开场接第一段**：发送后输入框和小球慢慢放大，iPad 上"正在思考…"的同一个问题淡进来，再出回答。
- **字幕**：上一段的字幕在交叠的前 10 帧淡出，这一段的字幕等交叠快结束才上来，两句话不会叠在一起。
- **段内换页**：错题本 → 复习、列出试卷 → 开始收集，右边的页面淡入淡出 10 帧；iPad → iPhone 是 iPad 往左退、iPhone 从右边进来，两者有交叠；iPad → PDF 是 iPad 缩小淡出、PDF 从同一个位置放大出来。
- 检查办法：渲染每个交界前后几十帧，算每帧的平均亮度和相邻两帧的差，亮度一路平滑过去、中间没有低谷就没有闪黑。

## 示例内容

- 回答和组件 JSON 在 [`promo/src/content.ts`](../../promo/src/content.ts)，格式和内置提示词要求的一样。`node promo/scripts/check-content.mjs` 用 `Renderer/core.js` 的解析函数检查每个组件都能解析。
- 化学平衡用的是 App 内置的 `equilibrium` 模拟，它只有通用的 A ⇌ B 和"中途加入 A"，没有压强参数。所以那一段讲的是加入反应物，不是加压。
- 演示数据（会话标题、连续学习 12 天、5 道错题、汇编的搜索次数和费用）都在真实使用能达到的范围内。汇编的用时和费用参照真机截图那次（搜索 29 次，约 ¥0.80）。
- **PDF 里的题目文字和合成路线图是示例**，不是哪份真实试卷的原文，图在 `promo/public/promo-assets/`。如果想放真实原题，要先用 App 生成一份汇编，把原题文字和原图换进 `promo/src/ui/PdfPage.tsx`，并确认网站允许这样使用。

## 原生界面怎么还原

| 画面 | 照着哪里写 |
|---|---|
| 侧栏 | `App/Views/ConversationListView.swift` |
| 聊天页、输入框 | `App/Views/ChatView.swift`、`ComposerView.swift`、`MessageRow.swift` |
| 今天 | `App/Study/TodayView.swift` |
| 错题本 | `App/Study/MistakeBookView.swift`、`App/Design/LibraryRow.swift` |
| 复习 | `App/Study/ReviewSessionView.swift` |
| 汇编、调用记录 | `App/Library/CompilationsView.swift`、`CollectionActivityView.swift`，调用记录的文字格式照 `CompilationToolbox.swift` |
| PDF 页眉页脚 | `App/Library/CompilationPDF.swift`；正文直接用渲染器的 `print.js` |

系统画的东西（`insetGrouped` 列表、导航栏、Liquid Glass、`safeAreaBar` 的模糊）只能用 CSS 仿，对照 `reference/` 里的截图。App 以后改了界面，片子不会跟着变。

`reference/` 是 iPad 真机截图（0.8.0，深色），只用来对照，不出现在片子里。

## 渲染器怎么按帧驱动

Remotion 每帧截一张图，真实时间和画面时间对不上，所以 `promo/public/promo-clock.js` 在渲染器的脚本之前加载，把它用到的计时都换成虚拟时钟：`requestAnimationFrame`、`setTimeout`、`performance.now`、`Date.now`、CSS 动画和过渡。`IntersectionObserver` 换成总是看得见，否则模拟不会开始播放。

拖滑块、点按钮、选测验选项都走渲染器自己的 DOM 事件（`promo/public/promo-bridge.js`），和用户在 App 里操作是同一条路。往回跳帧时重新载入页面，从这一段的开头快进，所以任何一帧都能单独渲染，多个标签页并行渲染也一样。

`scripts/prepare-renderer.mjs` 把 `Renderer/` 复制到 `promo/public/renderer/`，把 `prefers-color-scheme` 改成恒为深色，字体改成苹果系统字体（Chrome 不认渲染器里的 `-apple-system-body`），再给 Thinking Orbs 加一个按毫秒画一帧的入口。生成的文件不进仓库。

## 字体和图标

- 画面里的字体写的是 `-apple-system, "PingFang SC"`，直接用系统字体，仓库里不放字体文件。
- 图标用 SF Symbols。渲染前在同一台 Mac 上跑 `swift scripts/export-symbols.swift symbols.json public/symbols`，按 `promo/symbols.json` 的清单导出成 PNG。导出的图片不进仓库。
- 苹方、SF Pro 和 SF Symbols 只能在 Apple 平台上用，所以成片只在 macOS 上渲染（GitHub Actions 的 `macos-latest`）。在 Windows 或 Linux 上用 Remotion Studio 预览时，字体会换成别的，图标是空的，最终效果以 Actions 渲染出来的为准。

## 渲染

在 Actions 页面手动运行 **Promo video**：

- `stills` 留空：渲染整部片子，artifact `gewu-promo` 里有 `gewu-promo.mp4` 和 `cues.md`（音效时间表）。
- `release` 填 Release 的标签（例如 `v1.0.0`）：渲染完把成片以 `gewu-promo-1.0.0.mp4` 传到那个 Release 上。
- `stills` 填帧号（例如 `250,420,940`）：只出这几帧的截图，用来检查。

本地预览（需要 Node 22）：

```sh
cd promo
npm ci
npm run studio
```

成片挂到 GitHub Release 上，视频文件不进仓库。

## 配乐和剪映

配乐和音效已经在片子里了（`scripts/make-music.mjs` 生成 `public/music.wav`，渲染前跑一次；文件不进仓库）。改了 `timeline.json` 的段落或 cues 后重新生成，音乐的段落和音效会跟着走。

想换成别的音乐时，在剪映里把原声音量关掉，换上能商用的曲子，按 `cues.md` 补音效，曲名写在视频简介里。

## 还没做的

- 1.0 版的开场、片尾、字幕和"人格""还有这些"两段只在 Linux 上用思源黑体出过截图检查（图标那时是空的），以 Actions 渲染出来的为准。
- 0.8.0 那一版成片没在 macOS 上渲染过。开发时在 Linux 上用思源黑体代替苹方出过各段的截图检查，图标那时是空的。第一次运行 Actions 时先填 `stills` 看几帧，再渲染整部。
- 字体、玻璃、列表行高要和 `reference/` 的截图并排再比一遍。
