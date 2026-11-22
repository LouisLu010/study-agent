import Foundation
import JavaScriptCore

/// 复制消息时把组件代码块转成可读的文字。转换逻辑在渲染器的 core.js 里（和测试共用一份），
/// 这里用 JavaScriptCore 直接调用，不需要 WebView。
@MainActor
enum PlainTextExporter {
    private static let context: JSContext? = {
        guard let url = Bundle.main.url(forResource: "core", withExtension: "js", subdirectory: "Renderer"),
              let source = try? String(contentsOf: url, encoding: .utf8),
              let context = JSContext()
        else { return nil }
        // core.js 在没有 window 的环境里会挂到 self 上。
        context.evaluateScript("var self = this;")
        context.evaluateScript(source)
        return context
    }()

    static func plainText(from markdown: String) -> String {
        call("toPlainText", markdown)
    }

    /// 列表行用的一行文字：组件转成文字，公式改写成 x²/16 这样能读的样子。复制和导出不用它，仍保留 LaTeX。
    static func previewText(from markdown: String) -> String {
        call("toPreviewText", markdown)
    }

    private static func call(_ name: String, _ markdown: String) -> String {
        guard let core = context?.objectForKeyedSubscript("StudyCore"),
              let function = core.objectForKeyedSubscript(name),
              let result = function.call(withArguments: [markdown]),
              result.isString,
              let text = result.toString()
        else { return markdown }
        return text
    }
}
