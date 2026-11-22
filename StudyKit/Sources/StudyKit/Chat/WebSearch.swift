import Foundation

/// 联网搜索时看到或引用的一个网页。
public struct WebSource: Codable, Sendable, Equatable, Hashable {
    public var url: String
    public var title: String

    public init(url: String, title: String) {
        self.url = url
        self.title = title.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// 显示用的标题：服务商没给标题，或者标题就是链接时，用域名。
    public var displayTitle: String {
        if !title.isEmpty, title != url { return title }
        return host ?? url
    }

    public var host: String? {
        URL(string: url)?.host()?.replacingOccurrences(of: "www.", with: "")
    }
}

/// 一处引用应该插在回答的哪个位置。
public enum CitationAnchor: Sendable, Equatable {
    /// 插在当前已生成的正文末尾（Anthropic：一个带引用的文字块结束时）。
    case end
    /// 插在正文的第几个 Unicode 字符之后（DeepSeek、OpenAI 的 url_citation）。
    case offset(Int)
    /// 插在正文里这段文字的后面（Gemini 的 groundingSupports）。
    case afterText(String)
}

/// 回答里的一处引用：位置和引用的网页。
public struct Citation: Sendable, Equatable {
    public var sources: [WebSource]
    public var anchor: CitationAnchor

    public init(sources: [WebSource], anchor: CitationAnchor) {
        self.sources = sources
        self.anchor = anchor
    }
}

/// OpenAI 兼容协议下各家联网搜索的请求格式（见 docs/adr/0011）。
public enum WebSearchDialect: String, CaseIterable, Identifiable, Sendable {
    /// `web_search_options`，OpenAI 的 search 系列模型。
    case openAI
    /// `tools: [{"type": "deepseek_web_search"}]`。
    case deepSeek

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .openAI: "OpenAI（web_search_options）"
        case .deepSeek: "DeepSeek"
        }
    }

    /// 自动判断：地址或模型 ID 里有 deepseek 的按 DeepSeek，其余按 OpenAI。
    public static func resolve(raw: String, modelID: String, baseURL: String) -> WebSearchDialect {
        if let explicit = WebSearchDialect(rawValue: raw) { return explicit }
        let haystack = (modelID + " " + baseURL).lowercased()
        return haystack.contains("deepseek") ? .deepSeek : .openAI
    }
}

/// 一条回答的联网搜索记录，序列化后存在 `Message.webSearchJSON`。
public struct WebSearchRecord: Codable, Sendable, Equatable {
    /// 搜过的词，按顺序。
    public var queries: [String] = []
    /// 正文里引用的网页，按第一次引用的顺序编号（第 1 个就是 [1]）。
    public var sources: [WebSource] = []
    /// 搜索结果里出现过的网页（不一定被引用）。没有引用时用它们作为出处。
    public var results: [WebSource] = []
    /// 搜索次数，用来估算费用。
    public var count: Int = 0

    public init() {}

    public var isEmpty: Bool {
        queries.isEmpty && sources.isEmpty && results.isEmpty && count == 0
    }

    /// 回答下方列出的出处：有引用时只列引用的，否则列搜索结果。
    public var displayedSources: [WebSource] {
        sources.isEmpty ? results : sources
    }

    /// 显示的搜索次数：服务商没给次数但确实搜了时，至少算 1 次。
    public var effectiveCount: Int {
        if count > 0 { return count }
        return queries.count > 0 || !results.isEmpty || !sources.isEmpty ? max(1, queries.count) : 0
    }

    /// 复制和导出时附在正文后面的出处列表，例如"出处：\n[1] 标题 https://…"。没有出处时为 nil。
    public var sourcesText: String? {
        let list = displayedSources
        guard !list.isEmpty else { return nil }
        let numbered = !sources.isEmpty
        let lines = list.enumerated().map { index, source in
            (numbered ? "[\(index + 1)] " : "- ") + source.displayTitle + " " + source.url
        }
        return (["出处："] + lines).joined(separator: "\n")
    }

    public static func decode(_ json: String) -> WebSearchRecord? {
        guard !json.isEmpty, let value = try? JSONDecoder().decode(WebSearchRecord.self, from: Data(json.utf8)) else {
            return nil
        }
        return value
    }

    public func encode() -> String {
        guard !isEmpty, let data = try? JSONEncoder().encode(self) else { return "" }
        return String(decoding: data, as: UTF8.self)
    }
}

/// 生成过程中收集搜索事件：记下搜索词和出处，给引用编号，生成正文里的角标。
///
/// 角标写成 Markdown 链接 `[[1]](<url>)`，渲染器把它显示成上标；复制和导出时仍然是可用的链接。
public struct WebSearchRecorder: Sendable {
    public private(set) var record = WebSearchRecord()
    /// 生成结束后才能插入的引用（按位置或按文字定位）。
    private var deferred: [Citation] = []

    public init() {}

    /// 处理一个事件。返回值是要立即接在正文末尾的文字（角标），没有时为 nil。
    /// `content` 是到目前为止的正文，用来避免重复插入同一个角标。
    public mutating func handle(_ event: ChatStreamEvent, content: String) -> String? {
        switch event {
        case let .searching(query):
            if let query = query?.trimmingCharacters(in: .whitespacesAndNewlines), !query.isEmpty,
               !record.queries.contains(query) {
                record.queries.append(query)
            }
            return nil
        case let .searchResults(results):
            for source in results where !source.url.isEmpty && !record.results.contains(where: { $0.url == source.url }) {
                record.results.append(source)
            }
            return nil
        case let .searchCount(count):
            record.count = max(record.count, count)
            return nil
        case let .citations(citations):
            var immediate = ""
            for citation in citations {
                switch citation.anchor {
                case .end:
                    let marker = markers(for: citation.sources)
                    if !marker.isEmpty, !(content + immediate).hasSuffix(marker) { immediate += marker }
                case .offset, .afterText:
                    if !deferred.contains(citation) { deferred.append(citation) }
                }
            }
            return immediate.isEmpty ? nil : immediate
        case .text, .reasoning, .usage, .cachedInput, .toolCall, .thinkingBlock:
            return nil
        }
    }

    /// 生成结束后调用：把按位置或文字定位的引用插进正文，返回新的正文。
    public mutating func finish(content: String) -> String {
        var insertions: [(offset: Int, sources: [WebSource])] = []
        let scalars = Array(content.unicodeScalars)
        var cursor = 0
        for citation in deferred {
            switch citation.anchor {
            case let .offset(offset):
                insertions.append((min(max(0, offset), scalars.count), citation.sources))
            case let .afterText(text):
                guard !text.isEmpty, let end = Self.find(text, in: content, from: cursor) else { continue }
                cursor = end
                insertions.append((end, citation.sources))
            case .end:
                continue
            }
        }
        deferred = []
        guard !insertions.isEmpty else { return content }

        // 按位置排好序先编号（编号和阅读顺序一致），再从后往前插，前面的位置不会变。
        insertions.sort { $0.offset < $1.offset }
        let fences = Self.fencedRanges(in: scalars)
        var planned: [(offset: Int, marker: String)] = []
        for insertion in insertions {
            // 服务商已经在正文里写了这个链接（OpenAI 的 search 模型会这样做），
            // 或者位置在代码块里（会破坏组件的 JSON）：只记进出处，不加角标。
            let inFence = fences.contains { $0.contains(insertion.offset) }
            let linked = insertion.sources.filter { inFence || content.contains($0.url) }
            let sources = insertion.sources.filter { !inFence && !content.contains($0.url) }
            _ = markers(for: linked)
            guard !sources.isEmpty else { continue }
            let marker = markers(for: sources)
            if let last = planned.last, last.offset == insertion.offset {
                if !last.marker.contains(marker) { planned[planned.count - 1].marker += marker }
            } else {
                planned.append((insertion.offset, marker))
            }
        }
        var result = scalars
        for item in planned.reversed() {
            result.insert(contentsOf: item.marker.unicodeScalars, at: item.offset)
        }
        var view = String.UnicodeScalarView()
        view.append(contentsOf: result)
        return String(view)
    }

    /// 给这些网页编号，返回角标文字，例如 `[[1]](<https://a>)[[2]](<https://b>)`。
    private mutating func markers(for sources: [WebSource]) -> String {
        var text = ""
        var seen = Set<Int>()
        for source in sources where !source.url.isEmpty {
            let number: Int
            if let index = record.sources.firstIndex(where: { $0.url == source.url }) {
                number = index + 1
            } else {
                record.sources.append(source)
                number = record.sources.count
            }
            guard seen.insert(number).inserted else { continue }
            text += Self.marker(number: number, url: source.url)
        }
        return text
    }

    static func marker(number: Int, url: String) -> String {
        let safe = url
            .replacingOccurrences(of: " ", with: "%20")
            .replacingOccurrences(of: "<", with: "%3C")
            .replacingOccurrences(of: ">", with: "%3E")
        return "[[\(number)]](<\(safe)>)"
    }

    /// 在正文里从第 `from` 个 Unicode 字符开始找 `text`，返回它结束的位置。
    private static func find(_ text: String, in content: String, from: Int) -> Int? {
        let start = content.unicodeScalars.index(
            content.unicodeScalars.startIndex,
            offsetBy: min(from, content.unicodeScalars.count)
        )
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              let range = content.unicodeScalars[start...].firstRange(of: trimmed.unicodeScalars)
                ?? content.unicodeScalars.firstRange(of: trimmed.unicodeScalars)
        else { return nil }
        return content.unicodeScalars.distance(from: content.unicodeScalars.startIndex, to: range.upperBound)
    }

    /// ``` 代码块所占的位置范围（按 Unicode 字符计）。
    private static func fencedRanges(in scalars: [Unicode.Scalar]) -> [Range<Int>] {
        var ranges: [Range<Int>] = []
        var openStart: Int?
        var lineStart = 0
        var index = 0
        while index <= scalars.count {
            if index == scalars.count || scalars[index] == "\n" {
                let line = String(String.UnicodeScalarView(scalars[lineStart..<index]))
                if line.trimmingCharacters(in: .whitespaces).hasPrefix("```") {
                    if let start = openStart {
                        ranges.append(start..<(index + 1))
                        openStart = nil
                    } else {
                        openStart = lineStart
                    }
                }
                lineStart = index + 1
            }
            index += 1
        }
        if let start = openStart { ranges.append(start..<(scalars.count + 1)) }
        return ranges
    }
}

/// 解码失败时当作没有这个字段。用于各家格式不一的扩展字段，避免整个片段解析失败。
struct Lenient<Value: Decodable>: Decodable {
    let value: Value?

    init(from decoder: any Decoder) throws {
        value = try? decoder.singleValueContainer().decode(Value.self)
    }
}
