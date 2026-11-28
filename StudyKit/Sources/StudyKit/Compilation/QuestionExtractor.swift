import Foundation

/// 从题库网页里取出一道原题：按题干开头和最后一问开头的几个字定位，转成 Markdown（见 docs/adr/0013）。
/// 图片写成 `![](sa-image:N "w=宽,h=高")`，N 是 `imageURLs` 里的序号，下载后再换成 App 里的图片。
public enum QuestionExtractor {
    public struct Result: Sendable, Equatable {
        /// 题目 Markdown。
        public var content: String
        /// 网站附带的答案和解析 Markdown。没有时为空。
        public var answer: String
        /// 图片地址，序号和 `sa-image:N` 一致。
        public var imageURLs: [String]
        /// 题目部分的汉字数，用来判断是不是取到了整张试卷。
        public var questionLength: Int

        /// 题目文字里提到了图，但一张图都没取到。
        public var probablyMissingImages: Bool {
            guard !content.contains("](sa-image:") else { return false }
            return ["如下", "如图", "示意图", "路线", "装置", "结构简式为", "下图"].contains { content.contains($0) }
        }
    }

    public enum Failure: Error, Equatable, Sendable {
        /// 网页里找不到这道题。
        case notFound
        /// 找到的是整张试卷或很长的一段，不是单独的一道题。
        case tooLong
    }

    /// 一道大题的题目部分最多这么多汉字，超过就当作取到了整张试卷。
    static let maxQuestionLength = 1800
    /// 带阅读材料的题组（语言文字运用、现代文阅读、文言文阅读、完形填空等）最多这么多汉字。
    static let maxGroupLength = 6000

    /// 题目里说到"文中""材料"一类的词，说明这道题要配着一段阅读材料。
    static let passageReferences = ["文中", "材料", "上文", "下文", "选文", "短文", "这段文字", "下面的文字", "画横线", "画波浪线", "加点", "文段", "原文"]
    /// 阅读材料开头的说明，例如"阅读下面的文字，完成 18～20 题"。
    static let passageMarkers = ["阅读下面", "阅读下列", "阅读以下", "阅读材料", "阅读短文", "阅读文章", "完成各题", "完成下面小题", "完成小题"]

    /// 题号是不是一个范围，例如"18～20""18-20""18、19"。
    public static func isGroupNumber(_ number: String) -> Bool {
        number.range(of: #"\d\s*[～~\-—–至、,，]\s*\d"#, options: .regularExpression) != nil
    }

    static func needsPassage(_ text: String) -> Bool {
        passageReferences.contains { text.contains($0) } && !passageMarkers.contains { text.contains($0) }
    }

    /// 语言文字运用这类题，几道小题共用一段材料，模型给的定位字往往是某道小题的题干，取出来的只有小题、没有材料。
    /// 这时往上找最近一个包含材料说明（"阅读下面的文字……"）的元素，把材料和这一组小题一起取下来。找不到就用原来的。
    static func expandToPassage(_ block: HTMLNode, group: Bool) -> HTMLNode {
        guard needsPassage(block.text) || (group && !passageMarkers.contains { block.text.contains($0) }) else { return block }
        var node = block.parent
        while let current = node, current.tag != nil {
            let text = current.text
            if han(text).count > maxGroupLength { break }
            if passageMarkers.contains(where: { text.contains($0) }) { return current }
            node = current.parent
        }
        return block
    }

    /// group：题号是"18～20"这样的范围，说明是共用一段材料的一组题。
    public static func extract(html: String, baseURL: URL, anchor: String, lastAnchor: String, group: Bool = false) -> Swift.Result<Result, Failure> {
        let root = HTMLDocument.parse(html)
        guard let found = findBlock(in: root, anchor: anchor, lastAnchor: lastAnchor) else { return .failure(.notFound) }
        let block = expandToPassage(found, group: group)
        let isGroup = group || block !== found || passageMarkers.contains { found.text.contains($0) }
        var renderer = MarkdownRenderer(baseURL: baseURL)
        renderer.render(block)
        return renderedResult(&renderer, group: isGroup)
    }

    /// 锚点提取和整卷范围提取共用：分开网站答案并检查题目长度。
    static func renderedResult(_ renderer: inout MarkdownRenderer, group: Bool) -> Swift.Result<Result, Failure> {
        var (content, answer) = renderer.finish()
        // 有的网站把答案接在题目后面，用【答案】【解析】分开。
        for marker in ["【答案】", "【解析】", "【分析】", "【详解】", "【点睛】"] {
            if let range = content.range(of: marker) {
                let tail = String(content[range.lowerBound...])
                content = String(content[..<range.lowerBound])
                if !tail.contains("登录") && !tail.contains("会员") {
                    answer = [answer, tail].filter { !$0.isEmpty }.joined(separator: "\n\n")
                }
                break
            }
        }
        content = tidy(stripLeadingNumber(content))
        answer = tidy(answer)
        let length = han(content).count
        guard length <= (group ? maxGroupLength : maxQuestionLength) else { return .failure(.tooLong) }
        return .success(Result(content: content, answer: answer, imageURLs: renderer.imageURLs, questionLength: length))
    }

    /// 只留汉字。字母、公式在不同网站里可能是图片，比较时不算。
    static func han(_ text: String) -> String {
        String(String.UnicodeScalarView(text.unicodeScalars.filter { (0x4E00...0x9FFF).contains($0.value) }))
    }

    /// 同时包含题干开头和最后一问开头的最小元素。
    static func findBlock(in root: HTMLNode, anchor: String, lastAnchor: String) -> HTMLNode? {
        let first = String(han(anchor).prefix(6))
        let last = String(han(lastAnchor).prefix(5))
        guard !first.isEmpty else { return nil }
        // 每个元素的汉字只算一次：后序遍历，子元素的结果拼起来。
        var hanText: [ObjectIdentifier: String] = [:]
        func compute(_ node: HTMLNode) -> String {
            if let text = node.textValue { return han(text) }
            let value = node.children.map(compute).joined()
            hanText[ObjectIdentifier(node)] = value
            return value
        }
        _ = compute(root)
        var best: HTMLNode?
        var bestLength = Int.max
        for node in root.descendants() {
            guard let text = hanText[ObjectIdentifier(node)], text.count < bestLength,
                  text.contains(first), last.isEmpty || text.contains(last)
            else { continue }
            best = node
            bestLength = text.count
        }
        return best
    }

    /// 去掉网页自己加的题号，例如"1." "17．"。
    static func stripLeadingNumber(_ text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let match = trimmed.range(of: #"^\d{1,3}\s*[.．、]\s*(\(\d+分\)|（\d+分）)?\s*"#, options: .regularExpression) else {
            return trimmed
        }
        return String(trimmed[match.upperBound...])
    }

    /// 合并多余的空行和行尾空白；行首会被当成 Markdown 列表、标题的字符转义掉。
    static func tidy(_ text: String) -> String {
        let lines = text.components(separatedBy: "\n").map { line in
            var value = line
            while value.last == " " || value.last == "\u{00A0}" || value.last == "\t" { value.removeLast() }
            while value.first == " " || value.first == "\u{00A0}" { value.removeFirst() }
            if let match = value.range(of: #"^\d{1,3}(?=[.)] )"#, options: .regularExpression) {
                value.insert("\\", at: match.upperBound)
            } else if let first = value.first, "#>".contains(first) || ((first == "-" || first == "+") && value.dropFirst().first == " ") {
                value.insert("\\", at: value.startIndex)
            }
            return value
        }
        var result: [String] = []
        for line in lines {
            if line.trimmingCharacters(in: .whitespaces).isEmpty {
                if result.last?.isEmpty == false { result.append("") }
            } else {
                result.append(line)
            }
        }
        return result.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

/// 把一段 HTML 转成 Markdown。答案块（高途的 `[["…"]]` 和后面的解析）单独收集。
struct MarkdownRenderer {
    let baseURL: URL
    private(set) var imageURLs: [String] = []
    private var question = ""
    private var answers: [String] = []
    private var subQuestionCount = 0
    /// 正在往答案里写（渲染答案块内部时为 true）。
    private var target = Target.question

    private enum Target { case question, answer }

    static let blockTags: Set<String> = ["p", "div", "section", "article", "li", "ul", "ol", "h1", "h2", "h3", "h4", "h5", "h6", "dd", "dt", "dl", "blockquote", "center", "header", "footer", "pre"]
    /// 题号占位符，最后按小问个数换成 (1) (2) …，只有一问时去掉。
    static let numberMark = "\u{E000}"
    static let answerMark = "\u{E001}"

    init(baseURL: URL) {
        self.baseURL = baseURL
    }

    mutating func render(_ node: HTMLNode) {
        renderChildren(node.children)
    }

    /// 返回题目和答案。
    mutating func finish() -> (String, String) {
        var counter = 0
        let numbered = subQuestionCount >= 2
        var output = ""
        var rest = Substring(question)
        while let range = rest.range(of: Self.numberMark) {
            output += rest[..<range.lowerBound]
            counter += 1
            if numbered { output += "(\(counter)) " }
            rest = rest[range.upperBound...]
        }
        output += rest
        var answerCounter = 0
        let answerText = answers.joined(separator: "\n\n").components(separatedBy: Self.answerMark).enumerated().map { index, part in
            guard index > 0 else { return part }
            answerCounter += 1
            return (numbered ? "(\(answerCounter)) " : "") + part
        }.joined()
        return (output, answerText)
    }

    private mutating func write(_ text: String) {
        switch target {
        case .question: question += text
        case .answer:
            if answers.isEmpty { answers.append("") }
            answers[answers.count - 1] += text
        }
    }

    private mutating func renderChildren(_ children: [HTMLNode]) {
        var index = 0
        /// 上一个非空元素在题目里开始的位置（UTF-8 偏移）。
        var lastElementStart: Int?
        while index < children.count {
            let child = children[index]
            index += 1
            if let text = child.textValue {
                write(Self.escape(Self.collapse(text)))
                continue
            }
            // 高途：每一问后面跟着答案块 [["…"]]，再后面是解析块。
            if target == .question, child.text.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("[[") {
                if let offset = lastElementStart {
                    let start = question.utf8.index(question.startIndex, offsetBy: min(offset, question.utf8.count))
                    if !Self.startsWithNumber(question[start...]) {
                        question.insert(contentsOf: Self.numberMark, at: Self.firstVisible(in: question, from: start))
                    }
                }
                subQuestionCount += 1
                target = .answer
                answers.append("")
                write("**\(Self.answerMark)答案** ")
                renderAnswerJSON(child)
                write("\n\n")
                // 下一个非空元素是解析。
                while index < children.count {
                    let next = children[index]
                    index += 1
                    if next.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, !Self.hasImage(next) { continue }
                    write("**解析** ")
                    renderElement(next)
                    break
                }
                target = .question
                lastElementStart = nil
                continue
            }
            if !child.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || Self.hasImage(child) {
                lastElementStart = question.utf8.count
            }
            renderElement(child)
        }
    }

    private mutating func renderElement(_ node: HTMLNode) {
        guard let tag = node.tag else {
            if let text = node.textValue { write(Self.escape(Self.collapse(text))) }
            return
        }
        let className = node.className
        if className.contains("filling") {
            write("＿＿＿＿＿＿")
            return
        }
        switch tag {
        case "img":
            if let src = imageSource(node) {
                imageURLs.append(src)
                var size: [String] = []
                if let width = Self.number(node.attributes["width"]) { size.append("w=\(width)") }
                if let height = Self.number(node.attributes["height"]) { size.append("h=\(height)") }
                let title = size.isEmpty ? "" : " \"\(size.joined(separator: ","))\""
                write("![](sa-image:\(imageURLs.count - 1)\(title))")
            }
        case "br":
            write("\n\n")
        case "table":
            write("\n\n" + renderTable(node) + "\n\n")
        case "u":
            let inner = node.text.trimmingCharacters(in: .whitespaces.union(CharacterSet(charactersIn: "\u{00A0}")))
            if inner.isEmpty && !Self.hasImage(node) {
                write("＿＿＿＿＿＿")
            } else {
                renderChildren(node.children)
            }
        case "sub", "sup":
            let inner = node.text.trimmingCharacters(in: .whitespacesAndNewlines)
            if !inner.isEmpty, inner.count <= 8, !inner.contains("$"), !Self.hasImage(node) {
                write("$" + (tag == "sub" ? "_" : "^") + "{\(Self.texEscape(inner))}$")
            } else {
                renderChildren(node.children)
            }
        case "b", "strong":
            let inner = node.text.trimmingCharacters(in: .whitespacesAndNewlines)
            if inner.isEmpty || Self.hasImage(node) || inner.contains("$") {
                renderChildren(node.children)
            } else {
                write("**" + Self.escape(Self.collapse(inner)) + "**")
            }
        default:
            // 21 世纪教育网的选项是一串 span，每个选项单独一行。
            let isBlock = Self.blockTags.contains(tag) || className.contains("option__item") || className.contains("question__title")
            if isBlock { write("\n\n") }
            renderChildren(node.children)
            if isBlock { write("\n\n") }
        }
    }

    /// 高途的答案块是 JSON 数组的样子：[["<p>…</p>"],["…"]]，里面的反斜杠被转义了一次。
    private mutating func renderAnswerJSON(_ node: HTMLNode) {
        var inner = MarkdownRenderer(baseURL: baseURL)
        inner.imageURLs = imageURLs
        inner.renderChildren(node.children)
        imageURLs = inner.imageURLs
        var text = inner.question.replacingOccurrences(of: "\\\\", with: "\\")
        // 文字里的 [ ] 已经被转义成 \[ \]。
        for (wrapper, replacement) in [("\"\\],\\[\"", "\u{E002}"), ("\",\"", "\u{E002}"), ("\\[\\[\"", ""), ("\"\\]\\]", "")] {
            text = text.replacingOccurrences(of: wrapper, with: replacement)
        }
        text = text.replacingOccurrences(of: "\\s*\u{E002}\\s*", with: "；", options: .regularExpression)
        write(MarkdownRenderer.collapseBlankLines(text).trimmingCharacters(in: .whitespacesAndNewlines))
    }

    private mutating func renderTable(_ node: HTMLNode) -> String {
        let rows = node.descendants().filter { $0.tag == "tr" }
        var lines: [String] = []
        var columns = 0
        for (index, row) in rows.enumerated() {
            let cells = row.children.filter { $0.tag == "td" || $0.tag == "th" }.map { cell -> String in
                var inner = MarkdownRenderer(baseURL: baseURL)
                inner.imageURLs = imageURLs
                inner.renderChildren(cell.children)
                imageURLs = inner.imageURLs
                let text = inner.question
                    .replacingOccurrences(of: "\n", with: " ")
                    .replacingOccurrences(of: "|", with: "\\|")
                    .trimmingCharacters(in: .whitespaces)
                return text.isEmpty ? " " : text
            }
            columns = max(columns, cells.count)
            lines.append("| " + (cells + Array(repeating: " ", count: max(0, columns - cells.count))).joined(separator: " | ") + " |")
            if index == 0 {
                lines.append("|" + Array(repeating: " --- |", count: max(1, cells.count)).joined())
            }
        }
        return lines.joined(separator: "\n")
    }

    private func imageSource(_ node: HTMLNode) -> String? {
        for key in ["data-src", "data-original", "src"] {
            guard var value = node.attributes[key] else { continue }
            value = value.trimmingCharacters(in: CharacterSet(charactersIn: "\\\" "))
            guard !value.isEmpty, !value.hasPrefix("data:") else { continue }
            if value.hasPrefix("//") { value = "https:" + value }
            if let url = URL(string: value, relativeTo: baseURL)?.absoluteURL,
               url.scheme == "http" || url.scheme == "https" {
                return url.absoluteString
            }
        }
        return nil
    }

    static func hasImage(_ node: HTMLNode) -> Bool {
        node.descendants().contains { $0.tag == "img" }
    }

    static func number(_ value: String?) -> Int? {
        guard let value else { return nil }
        let digits = value.trimmingCharacters(in: CharacterSet(charactersIn: "\\\" px"))
        return Int(digits).flatMap { $0 > 0 ? $0 : nil }
    }

    static func startsWithNumber(_ text: Substring) -> Bool {
        let trimmed = text.drop { $0.isWhitespace }
        guard let first = trimmed.first else { return false }
        return first == "(" || first == "（" || "①②③④⑤⑥⑦⑧⑨⑩".contains(first)
    }

    static func firstVisible(in text: String, from start: String.Index) -> String.Index {
        text[start...].firstIndex { !$0.isWhitespace } ?? text.endIndex
    }

    /// 网页里的换行和连续空白合成一个空格（HTML 的显示规则）。
    static func collapse(_ text: String) -> String {
        text.replacingOccurrences(of: "[ \\t\\r\\n]+", with: " ", options: .regularExpression)
    }

    static func collapseBlankLines(_ text: String) -> String {
        text.replacingOccurrences(of: "\n{3,}", with: "\n\n", options: .regularExpression)
    }

    static func texEscape(_ text: String) -> String {
        text.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "{", with: "\\{")
            .replacingOccurrences(of: "}", with: "\\}")
    }

    /// 转义 Markdown 的特殊字符，`$…$` 公式里的不动。
    static func escape(_ text: String) -> String {
        var result = ""
        var inMath = false
        for char in text {
            if char == "$" { inMath.toggle(); result.append(char); continue }
            if !inMath, "*_`[]".contains(char) { result.append("\\") }
            result.append(char)
        }
        return result
    }
}
