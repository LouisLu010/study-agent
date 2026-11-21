import Foundation

/// 把会话或一条回答整理成资料：准备发给模型的材料，解析模型的输出，处理正文里的引用。
public enum ResearchNoteWriter {
    /// 整理用的一条消息。
    public struct Item: Sendable, Equatable {
        public var role: ChatRole
        public var content: String
        public var sources: [WebSource]

        public init(role: ChatRole, content: String, sources: [WebSource] = []) {
            self.role = role
            self.content = content
            self.sources = sources
        }
    }

    /// 模型整理出的资料。
    public struct Draft: Sendable, Equatable {
        public var title: String
        public var subject: Subject?
        public var topic: String
        /// 正文 Markdown，引用已经换成角标 `[[1]](<url>)`。
        public var content: String
        /// 出处，编号和正文里的角标一致。
        public var sources: [WebSource]
    }

    /// 发给模型的说明，接在内置格式规则后面。
    public static let instructions = """
    你的任务是把下面的学习对话整理成一份"资料"：一篇结构清楚、可以单独阅读的总结，用来以后复习。
    要求：
    1. 只整理对话里已有的内容，不要补充对话里没有的事实。对话里的结论有出处时，在句子后面用 [1]、[2] 这样的编号注明，编号对应"出处列表"里的序号；没有出处的内容不要编号。
    2. 用小标题分节，先给要点，再给细节。公式、化学式按格式规则书写；确实有帮助时可以用组件。
    3. 不要写"根据对话""用户问了"之类的话，直接写内容。
    4. 严格按下面的格式输出，前三行之后是一行 ---，再往后是正文：
    标题：不超过 20 个字
    科目：数学、物理、化学、生物、语文、英语、其他 之一
    知识点：不超过 12 个字
    ---
    正文
    """

    /// 把消息整理成发给模型的文字和统一编号的出处列表。消息里原有的角标换成新的编号 [n]。
    public static func prepare(_ items: [Item]) -> (text: String, sources: [WebSource]) {
        var sources: [WebSource] = []
        func number(for source: WebSource) -> Int {
            if let index = sources.firstIndex(where: { $0.url == source.url }) { return index + 1 }
            sources.append(source)
            return sources.count
        }
        var parts: [String] = []
        for item in items where !item.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            item.sources.forEach { _ = number(for: $0) }
            let content = replaceMarkers(in: item.content) { url in
                if let source = item.sources.first(where: { $0.url == url }) ?? sources.first(where: { $0.url == url }) {
                    return "[\(number(for: source))]"
                }
                return ""
            }
            parts.append((item.role == .user ? "【提问】\n" : "【回答】\n") + content)
        }
        var text = parts.joined(separator: "\n\n")
        if !sources.isEmpty {
            let list = sources.enumerated().map { "[\($0.offset + 1)] \($0.element.displayTitle) \($0.element.url)" }
            text += "\n\n【出处列表】\n" + list.joined(separator: "\n")
        }
        return (text, sources)
    }

    /// 解析模型的输出。没有按格式写时，整段当正文，标题用 `fallbackTitle`。
    public static func parse(_ raw: String, sources: [WebSource], fallbackTitle: String) -> Draft {
        var title = ""
        var subject: Subject?
        var topic = ""
        var body = raw
        let lines = raw.components(separatedBy: "\n")
        if let separator = lines.prefix(8).firstIndex(where: { $0.trimmingCharacters(in: .whitespaces) == "---" }) {
            for line in lines[..<separator] {
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                if let value = field(trimmed, "标题") { title = value }
                if let value = field(trimmed, "科目") { subject = Subject.normalize(value) }
                if let value = field(trimmed, "知识点") { topic = value }
            }
            body = lines[(separator + 1)...].joined(separator: "\n")
        }
        body = body.trimmingCharacters(in: .whitespacesAndNewlines)
        // 正文开头重复了标题时去掉。
        if let first = body.components(separatedBy: "\n").first, first.hasPrefix("#"),
           first.trimmingCharacters(in: CharacterSet(charactersIn: "# ")) == title {
            body = body.components(separatedBy: "\n").dropFirst().joined(separator: "\n")
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
        let cited = citeSources(in: body, sources: sources)
        return Draft(
            title: title.isEmpty ? fallbackTitle : String(title.prefix(30)),
            subject: subject,
            topic: String(topic.prefix(20)),
            content: cited.content,
            sources: cited.sources
        )
    }

    private static func field(_ line: String, _ name: String) -> String? {
        for separator in ["：", ":"] where line.hasPrefix(name + separator) {
            let value = line.dropFirst(name.count + 1).trimmingCharacters(in: .whitespaces)
            return value.isEmpty ? nil : value
        }
        return nil
    }

    /// 把正文里的 [n] 换成角标，按第一次引用的顺序重新编号。没有任何引用时保留全部出处。
    /// 代码块和公式里的 [n] 不动。
    public static func citeSources(in body: String, sources: [WebSource]) -> (content: String, sources: [WebSource]) {
        guard !sources.isEmpty else { return (body, []) }
        var used: [WebSource] = []
        let pattern = try! NSRegularExpression(pattern: #"(?<!\[)\[(\d{1,3})\](?![\(\]])"#)
        var inFence = false
        var lines: [String] = []
        for line in body.components(separatedBy: "\n") {
            if line.trimmingCharacters(in: .whitespaces).hasPrefix("```") {
                inFence.toggle()
                lines.append(line)
                continue
            }
            guard !inFence else { lines.append(line); continue }
            let math = mathRanges(in: line)
            var result = line
            let ns = line as NSString
            for match in pattern.matches(in: line, range: NSRange(location: 0, length: ns.length)).reversed() {
                guard !math.contains(where: { NSIntersectionRange($0, match.range).length > 0 }),
                      let n = Int(ns.substring(with: match.range(at: 1))), sources.indices.contains(n - 1)
                else { continue }
                let source = sources[n - 1]
                let number: Int
                if let index = used.firstIndex(where: { $0.url == source.url }) {
                    number = index + 1
                } else {
                    used.append(source)
                    number = used.count
                }
                result = (result as NSString).replacingCharacters(
                    in: match.range, with: WebSearchRecorder.marker(number: number, url: source.url)
                )
            }
            lines.append(result)
        }
        // 编号是从后往前替换时分配的，再按阅读顺序统一一次。
        let content = renumber(lines.joined(separator: "\n"), sources: used)
        return used.isEmpty ? (body, sources) : (content.content, content.sources)
    }

    /// 删除第 `index` 个出处：去掉正文里指向它的角标，其余角标重新编号。
    public static func removeSource(at index: Int, sources: [WebSource], content: String) -> (content: String, sources: [WebSource]) {
        guard sources.indices.contains(index) else { return (content, sources) }
        var remaining = sources
        let removed = remaining.remove(at: index)
        let stripped = replaceMarkers(in: content) { url in url == removed.url ? "" : nil }
        return renumber(stripped, sources: remaining)
    }

    /// 按正文里第一次出现的顺序重新给角标编号；正文里没出现的出处排在后面。
    static func renumber(_ content: String, sources: [WebSource]) -> (content: String, sources: [WebSource]) {
        var order: [WebSource] = []
        _ = replaceMarkers(in: content) { url in
            if !order.contains(where: { $0.url == url }), let source = sources.first(where: { $0.url == url }) {
                order.append(source)
            }
            return nil
        }
        order += sources.filter { source in !order.contains(where: { $0.url == source.url }) }
        let result = replaceMarkers(in: content) { url in
            guard let index = order.firstIndex(where: { $0.url == url }) else { return nil }
            return WebSearchRecorder.marker(number: index + 1, url: url)
        }
        return (result, order)
    }

    /// 逐个替换角标 `[[n]](<url>)`。`transform` 返回 nil 表示保留原样。
    static func replaceMarkers(in text: String, _ transform: (String) -> String?) -> String {
        let pattern = try! NSRegularExpression(pattern: #"\[\[\d{1,3}\]\]\(<([^>\n]*)>\)"#)
        let ns = text as NSString
        var result = ""
        var cursor = 0
        for match in pattern.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
            result += ns.substring(with: NSRange(location: cursor, length: match.range.location - cursor))
            let url = ns.substring(with: match.range(at: 1))
            result += transform(url) ?? ns.substring(with: match.range)
            cursor = match.range.location + match.range.length
        }
        result += ns.substring(from: cursor)
        return result
    }

    /// 一行里 `$...$` 公式的位置。
    private static func mathRanges(in line: String) -> [NSRange] {
        let pattern = try! NSRegularExpression(pattern: #"\$\$?[^$]+\$\$?"#)
        return pattern.matches(in: line, range: NSRange(location: 0, length: (line as NSString).length)).map(\.range)
    }
}
