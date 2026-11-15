# 模型消息用 WebView + KaTeX 渲染

学习类回答要显示公式和化学式（mhchem 的 `\ce{}` 语法），而纯原生的 Swift 公式库不支持化学式。所以每条模型消息用一个 WKWebView 显示，在里面用 markdown-it 解析 Markdown，KaTeX 加 mhchem 扩展渲染公式和化学式，同时负责代码高亮。为了控制长会话的内存占用，只给屏幕上可见的消息创建 WebView，并缓存已生成完的消息的渲染结果。

## Considered Options

- 原生 SwiftUI 排版，公式交给 JavaScriptCore 里的 MathJax 转成 SVG：界面更原生，但表格、代码块、公式要自己拼起来，流式输出时的增量更新也要自己实现。
- 纯原生公式库（SwiftMath / iosMath）：不支持化学式。

## Consequences

文字选择和长按菜单都在 WebView 里，"复制公式源码"这类操作要通过 JS 和 Swift 之间传消息来实现。WebView 的高度要根据内容动态计算，再回传给 SwiftUI。
