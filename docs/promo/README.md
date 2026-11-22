# 格物宣传片

一部 60 秒的横屏宣传片，整部用 [Remotion](https://www.remotion.dev/) 按帧生成。工程在 [`promo/`](../../promo/)。

## 定下来的事

| | 决定 |
|---|---|
| 观众 | 同学、朋友和 B 站上的高中生，看完想试试；成片也放进仓库 README |
| 版本 | 0.8.0（第八版） |
| 画幅和片长 | 横屏 16:9，1920×1080，30 fps，60 秒 |
| 外观 | 深色模式，iOS 26（玻璃输入框、滚动边缘模糊） |
| 设备 | iPad 横屏为主，放在画面右边约 62% 宽；"今天"那个镜头换成 iPhone。设备框是自己画的圆角矩形，不用 Apple 的产品图 |
| 原生界面 | 不录屏。照 SwiftUI 代码用 React 还原，样式常量抄自 `App/Design/Theme.swift`，对照 `reference/` 里的真机截图 |
| 组件 | 用 App 的渲染器（`Renderer/`）在 iframe 里直接画，组件 JSON 是手写的 |
| 小球 | Thinking Orbs 0.1.2 的原版（App 里的 SwiftUI 版是从它移植的），只表示状态，不拟人。开场和片尾用大号 `idle` 小球 |
| 声音 | 不配旁白。Remotion 只出无声成片和音效时间表，音乐和音效在剪映里加 |
| 字体和图标 | 苹果系统字体（苹方、SF Pro）和 SF Symbols，只在 macOS 上渲染，见下面"字体和图标" |
| 片尾 | "格物"、"格物致知"、`github.com/LouisLu010/study-agent`，最后一行"界面为按 App 还原的演示画面，示例内容为预设"。不提安装门槛 |

## 分镜

镜头切换对齐 120 BPM（每 0.5 秒一拍）。帧号和字幕的准数在 [`promo/src/timeline.json`](../../promo/src/timeline.json)。

| 时间 | 段落 | 画面 | 字幕 |
|---|---|---|---|
| 0:00–0:05 | 开场 | 黑底，大号小球和"格物"出现；输入框里打出"摆长变长，单摆会摆得更慢吗？"，按下发送，小球切到 `reasoning` | — |
| 0:05–0:11.5 | 单摆 | 镜头贴着模拟卡片。拖摆长 1 m → 2.5 m，淡色虚影留下原来的样子；松手后摆起来，能量柱实时变化；最后拉远露出整台 iPad | 摆长、周期、能量，直接看得见 |
| 0:11.5–0:18 | 坐标图 | 拖参数 a 0.5 → 2.2，y = x² − 2ax + 1 跟着平移，自动标出的零点和极小值跟着走，读数实时变 | 参数一拖，图像跟着变 |
| 0:18–0:24 | 化学平衡 | 点 2×，A ⇌ B 先达到平衡，中途加入 A，浓度曲线跳一下再走到新的平衡 | 加入反应物，平衡往哪边移 |
| 0:24–0:30 | 测验 | 第 1 题选对（绿勾），第 2 题选错（左右抖、红叉），下面出现"已加入错题本" | 做错的题，自动进错题本 |
| 0:30–0:40 | 错题和复习 | 错题本里插进刚才那道题 → 点"开始复习" → 复习答对，第 1 档升到第 2 档 → 换成 iPhone 上的"今天"，连续学习天数从 11 变成 12 | 隔 1、3、7、14、30 天，再考你一次 |
| 0:40–0:52 | 汇编 | 新建汇编输入"近 3 年高考有机大题" → 找到 9 份试卷 → 开始收集，调用记录一行行往上滚，小球在 `searching` 和 `background` 之间切换 → 生成的 A4 PDF，翻到第 2 页 | 一句话，汇编高考原题 / 原题取自出处网页，不由模型改写 |
| 0:52–1:00 | 片尾 | 见上表 | — |

几何图、图表、分步讲解、联网搜索的出处卡片这次不拍。

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
- `stills` 填帧号（例如 `250,420,940`）：只出这几帧的截图，用来检查。

本地预览（需要 Node 22）：

```sh
cd promo
npm ci
npm run studio
```

成片挂到 GitHub Release 上，视频文件不进仓库。

## 剪映里要做的

1. 导入 `gewu-promo.mp4`。
2. 选一首 110–130 BPM、能商用的轻电子或钢琴曲（B 站音乐库或 YouTube 音频库），曲名写在视频简介里。音频文件不进仓库，免版权音乐的许可一般也不允许再分发。
3. 按 `cues.md` 在发送、答对、答错、档位升级、翻页这些时刻加音效。
4. 简介里写"源码公开、MIT 许可"和仓库地址。

## 还没做的

- 成片没在 macOS 上渲染过。开发时在 Linux 上用思源黑体代替苹方出过各段的截图检查，图标那时是空的。第一次运行 Actions 时先填 `stills` 看几帧，再渲染整部。
- 字体、玻璃、列表行高要和 `reference/` 的截图并排再比一遍。
