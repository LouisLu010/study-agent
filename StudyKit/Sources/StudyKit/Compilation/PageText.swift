import Foundation

/// 网页正文：给 read_page 用，让模型看整卷页面上有哪些题、核对题号和题型（见 docs/adr/0014）。
/// 去掉脚本和标签，块级元素换行，图片写成 [图]。
public enum PageText {
    public struct Page: Sendable, Equatable {
        public var title: String
        public var text: String
    }

    static let breakTags: Set<String> = MarkdownRenderer.blockTags.union(["br", "tr", "table", "hr"])

    public static func extract(html: String) -> Page {
        let root = HTMLDocument.parse(html)
        var text = ""
        func walk(_ node: HTMLNode) {
            if let value = node.textValue {
                text += MarkdownRenderer.collapse(value)
                return
            }
            guard let tag = node.tag else { return }
            if tag == "img" { text += "[图]"; return }
            let isBreak = breakTags.contains(tag)
            if isBreak { text += "\n" }
            for child in node.children { walk(child) }
            if isBreak { text += "\n" }
            if tag == "td" || tag == "th" { text += " " }
        }
        walk(root)
        return Page(title: title(in: html), text: tidy(text))
    }

    /// 合并空白和空行。
    static func tidy(_ text: String) -> String {
        text.replacingOccurrences(of: "[ \t\u{00A0}\u{3000}]+", with: " ", options: .regularExpression)
            .replacingOccurrences(of: " *\\n[ \\n]*", with: "\n", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// `<title>` 的文字。HTMLDocument 会丢掉 title 的内容，所以单独取。
    static func title(in html: String) -> String {
        guard let range = html.range(of: #"<title[^>]*>([\s\S]*?)</title>"#, options: [.regularExpression, .caseInsensitive]) else {
            return ""
        }
        let inner = html[range]
            .replacingOccurrences(of: #"^<title[^>]*>"#, with: "", options: [.regularExpression, .caseInsensitive])
            .replacingOccurrences(of: #"</title>$"#, with: "", options: [.regularExpression, .caseInsensitive])
        return HTMLDocument.decodeEntities(inner).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// DeepSeek Fetch API 返回的 Markdown 转成读网页用的正文：图片写成 [图]，链接只留文字。
    public static func fromMarkdown(_ markdown: String) -> String {
        tidy(markdown
            .replacingOccurrences(of: #"!\[[^\]]*\]\([^)]*\)"#, with: "[图]", options: .regularExpression)
            .replacingOccurrences(of: #"\[([^\]]*)\]\([^)]*\)"#, with: "$1", options: .regularExpression))
    }

    /// Fetch API 的 Markdown 转成简单的 HTML，好用 QuestionExtractor 按那几个字定位。
    /// 每一行一个 `<p>`；图片已经没有了（Fetch API 只给文字），所以取到的题都算"有图未能获取"。
    public static func html(fromMarkdown markdown: String) -> String {
        let lines = fromMarkdown(markdown).components(separatedBy: "\n").map { line -> String in
            let escaped = line
                .replacingOccurrences(of: "&", with: "&amp;")
                .replacingOccurrences(of: "<", with: "&lt;")
                .replacingOccurrences(of: ">", with: "&gt;")
            return "<p>\(escaped)</p>"
        }
        return "<html><body><div>" + lines.joined(separator: "\n") + "</div></body></html>"
    }
}
