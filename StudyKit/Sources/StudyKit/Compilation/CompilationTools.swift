import Foundation

/// 汇编用的内置工具（见 docs/adr/0014）：名字、参数说明、三个阶段的提示词，以及参数检查。
/// 工具由 App 执行，这里只放和设备无关的部分，便于测试。
public enum CompilationTools {
    public enum Name: String, CaseIterable, Sendable {
        case searchWeb = "search_web"
        case readPage = "read_page"
        case fetchQuestion = "fetch_question"
        case removeQuestion = "remove_question"
        case finishPaper = "finish_paper"
        case submitPapers = "submit_papers"
        case arrange
        case makePDF = "make_pdf"
    }

    // MARK: - 上限

    /// 每份试卷最多调用工具的次数，到了就按已取到的结果结束这份。
    public static let maxCallsPerPaper = 40
    /// 列试卷最多调用工具的次数。
    public static let maxCallsForListing = 30
    /// 整理最多调用工具的次数。
    public static let maxCallsForArranging = 6
    /// 连续这么多次调用没有新进展（没取到新题、没读到新网站）就结束这份试卷（C0 的结论）。
    public static let maxCallsWithoutProgress = 8
    /// read_page 交给模型的正文最多这么多字。
    public static let pageTextLimit = 8000
    /// fetch_question 交给模型核对的原题文字最多这么多字。
    public static let questionTextLimit = 2500

    // MARK: - 工具声明

    private static func object(_ properties: [String: JSONValue], required: [String]) -> JSONValue {
        ["type": "object", "properties": .object(properties), "required": .array(required.map { .string($0) })]
    }

    private static func string(_ description: String) -> JSONValue {
        ["type": "string", "description": .string(description)]
    }

    static let searchWeb = ToolDefinition(
        name: Name.searchWeb.rawValue,
        description: "联网搜索，返回最多 8 个网页的标题、网址和摘要。",
        parameters: object(["query": string("搜索词，不超过 60 个字")], required: ["query"])
    )

    static let readPage = ToolDefinition(
        name: Name.readPage.rawValue,
        description: "下载一个网页，返回去掉标签后的正文（最多约 \(pageTextLimit) 字，图片写成[图]）。用来查看整卷页面上有哪些题、核对题号和题型。",
        parameters: object(["url": string("网页地址")], required: ["url"])
    )

    static let fetchQuestion = ToolDefinition(
        name: Name.fetchQuestion.rawValue,
        description: """
        App 从网页里取出一道原题（文字和原图）并保存进汇编。anchor 是题干开头约 15 个字，last_anchor 是最后一问开头约 10 个字，都要逐字照抄网页上的文字。\
        几道小题共用一段材料时整组取一次：number 写成"18～20"，anchor 用材料正文的开头。\
        同一题号再取一次时，新结果更完整才替换。\
        返回 status：complete 完整；images_missing 取到了文字但有图没取到；not_found 网页上找不到这几个字；too_long 像是整卷不是一道题；refused 网站拒绝访问；failed 下载失败。\
        同时返回取到的文字（图写成[图1]）和有没有网站解析。不是 complete 时可以换网址再试。
        """,
        parameters: object([
            "number": string("题号，例如 17 或 18～20"),
            "url": string("题目所在的网页地址"),
            "anchor": string("题干（或材料）开头约 15 个字，逐字照抄"),
            "last_anchor": string("最后一问开头约 10 个字，逐字照抄；只有一问时可以不填"),
        ], required: ["number", "url", "anchor"])
    )

    static let removeQuestion = ToolDefinition(
        name: Name.removeQuestion.rawValue,
        description: "核对后发现题型或内容不符合要求时，去掉这份试卷里已经取到的一道题。",
        parameters: object(["number": string("题号"), "reason": string("为什么去掉")], required: ["number", "reason"])
    )

    static let finishPaper = ToolDefinition(
        name: Name.finishPaper.rawValue,
        description: "这份试卷查完了。没有符合要求的题、或者取不到原题时也要调用，在 note 里说明。",
        parameters: object(["note": string("一句话说明结果")], required: ["note"])
    )

    static let submitPapers = ToolDefinition(
        name: Name.submitPapers.rawValue,
        description: "列出符合要求、确实存在的试卷，交给用户确认。调用后这一步就结束了。",
        parameters: object([
            "title": string("汇编标题，不超过 20 个字"),
            "subject": ["type": "string", "enum": ["数学", "物理", "化学", "生物", "语文", "英语", "其他"]],
            "papers": [
                "type": "array",
                "items": object([
                    "title": string("试卷全称，例如 2025 年普通高等学校招生全国统一考试（北京卷）化学"),
                    "short": string("简称，例如 北京卷、新课标卷（理综）、海淀一模"),
                    "year": string("年份，例如 2025"),
                ], required: ["title", "year"]),
            ],
        ], required: ["title", "subject", "papers"])
    )

    static let arrange = ToolDefinition(
        name: Name.arrange.rawValue,
        description: "定汇编的标题和题目顺序。groups 可以按知识点或年份分组，组名印在 PDF 里；不分组时只给 order。每道题用列表里的编号（例如 Q3），每道题只出现一次。",
        parameters: object([
            "title": string("汇编标题，不超过 20 个字"),
            "order": ["type": "array", "items": ["type": "string"], "description": "不分组时的题目顺序"],
            "groups": [
                "type": "array",
                "items": object([
                    "name": string("组名，例如 有机合成路线 或 2025 年"),
                    "items": ["type": "array", "items": ["type": "string"]],
                ], required: ["name", "items"]),
            ],
        ], required: ["title"])
    )

    static let makePDF = ToolDefinition(
        name: Name.makePDF.rawValue,
        description: "按定好的顺序生成 PDF。调用后这一步就结束了。",
        parameters: object(["include_answers": ["type": "boolean", "description": "PDF 里附不附答案和解析"]], required: ["include_answers"])
    )

    public static let listingTools = [searchWeb, readPage, submitPapers]
    public static let paperTools = [searchWeb, readPage, fetchQuestion, removeQuestion, finishPaper]
    public static let arrangingTools = [arrange, makePDF]

    // MARK: - 提示词

    /// 列试卷：一轮工具循环，最后调用 submit_papers。
    public static func listingRequest(
        model: String, request: String, reasoningEffort: ReasoningEffort?, today: Date = .now
    ) -> ChatRequest {
        ChatRequest(
            model: model,
            systemPrompt: """
            你是一名教研员，负责整理考试题目汇编。今天是 \(CompilationPlanner.dateText(today))。
            用户会说要哪类题。请用 search_web 搜索、必要时用 read_page 打开网页核实，列出符合要求、已经公开的真实试卷（考试类型不限：高考、中考、模拟考、期中期末考都可以，按用户的要求来），最后调用 submit_papers。
            要求：
            1. 只列确实存在、已经考过的试卷，不要编造。每一份都要先搜索核实它当年确实存在（各地每年用的试卷会变，例如有的年份起不再有某种全国卷），核实不了的不要列。每份试卷单独一项，不要重复。
            2. 卷名要写清楚，不要有歧义。例如 2025 年"新课标卷"是理综卷，要写成"新课标卷（理综）"，不要和"新高考Ⅰ卷"或某个省的卷子混在一起。
            3. "近 N 年"按今天往前算；用户没说范围时，列最近 3 年最主要的几份。
            """,
            messages: [ChatMessage(role: .user, text: request)],
            reasoningEffort: reasoningEffort,
            tools: listingTools
        )
    }

    /// 已经取到的一道题，列在查题提示词的开头，中断后从头再来时不重复取。
    public struct ExistingQuestion: Sendable, Equatable {
        public var number: String
        public var status: ExamQuestionStatus

        public init(number: String, status: ExamQuestionStatus) {
            self.number = number
            self.status = status
        }
    }

    /// 查一份试卷：一轮工具循环，最后调用 finish_paper。onlyNumber 不为空时只找这一道题（"重新获取"）。
    public static func paperRequest(
        model: String, request: String, paper: PaperPlan, existing: [ExistingQuestion],
        onlyNumber: String? = nil, reasoningEffort: ReasoningEffort?
    ) -> ChatRequest {
        var task = "试卷：\(paper.title)"
        if let onlyNumber {
            task += "\n只找这份试卷的第 \(onlyNumber) 题。App 之前没取完整，请换网页重新取。"
        } else {
            task += "\n找出这份试卷里所有符合要求的题，逐一取下来。"
        }
        let done = existing.filter { $0.number != onlyNumber }
        if !done.isEmpty {
            let list = done.map { "第 \($0.number) 题（\($0.status == .complete ? "完整" : $0.status == .imagesMissing ? "有图未能获取" : "未能获取原文")）" }
            task += "\n这份试卷已经取到：\(list.joined(separator: "、"))。完整的不要再取；不完整的可以换网址再取一次。"
        }
        return ChatRequest(
            model: model,
            systemPrompt: """
            你是一名严谨的教研员，正在为一份考试题汇编收集原题。原题必须由 App 从网页上取，你不能自己抄写或改写题目。
            可以用的工具：search_web 搜索；read_page 读网页正文；fetch_question 让 App 取一道题；remove_question 去掉取错的题；finish_paper 结束这份试卷。
            做法：
            1. 先搜索，确认这份试卷里哪几道题符合要求（题号和题型）。必要时用 read_page 读整卷页面核对。
            2. 每道题优先找"每道题单独一个页面"的题目详情页，例如 gaotu.cn/topic/…、zujuan.21cnjy.com/question/detail/…、菁优网的试题页；其次才是整卷页面。不要用需要下载文档、登录或付费才能看到题目的页面，也不要用公众号文章和小红书。
            3. 用 fetch_question 取题。看返回的文字核对题号和题型；结果不是 complete 就换一个网址再试。同一个网址取不到时不要反复试。
            4. 几道小题共用一段阅读材料时（语言文字运用、现代文阅读、文言文阅读、古诗词阅读、完形填空、阅读理解、语法填空等），整组只取一次：number 写成"18～20"，anchor 用材料正文开头约 15 个字（不是"阅读下面的文字"这类说明），last_anchor 用这组最后一道小题开头。
            5. 题型不符合要求就不要取；取错了用 remove_question 去掉。没有符合要求的题不要编造。
            6. 全部取完后调用 finish_paper。实在取不到原题时，也调用 finish_paper 说明情况。

            要求：\(request)
            """,
            messages: [ChatMessage(role: .user, text: task)],
            reasoningEffort: reasoningEffort,
            tools: paperTools
        )
    }

    /// 整理时列给模型的一道题。
    public struct ArrangeItem: Sendable, Equatable {
        public var id: String
        public var label: String
        public var preview: String

        public init(id: String, label: String, preview: String) {
            self.id = id
            self.label = label
            self.preview = preview
        }
    }

    /// 整理：一轮工具循环，只能用 arrange 和 make_pdf。
    public static func arrangingRequest(
        model: String, request: String, title: String, items: [ArrangeItem], reasoningEffort: ReasoningEffort?
    ) -> ChatRequest {
        let list = items.map { "\($0.id)　\($0.label)　\($0.preview)" }.joined(separator: "\n")
        return ChatRequest(
            model: model,
            systemPrompt: """
            你是一名教研员，正在整理一份考试题汇编。题目已经取好了，不要改题目内容。
            先调用 arrange 定汇编标题和题目顺序：题目多、知识点不同时按知识点分组（组名简短，例如"有机合成路线"），否则按年份从新到旧排；同一份试卷的题按题号排。然后调用 make_pdf 生成 PDF，一般附答案和解析。
            """,
            messages: [ChatMessage(role: .user, text: "要求：\(request)\n现在的标题：\(title)\n共 \(items.count) 题：\n\(list)")],
            reasoningEffort: reasoningEffort,
            tools: arrangingTools
        )
    }

    // MARK: - 参数检查

    /// 必填的文字参数；没有时返回给模型看的错误。
    public static func requiredString(_ input: JSONValue, _ key: String) -> Swift.Result<String, ArgumentError> {
        let value = input[key]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return value.isEmpty ? .failure(ArgumentError("缺少参数 \(key)")) : .success(value)
    }

    public struct ArgumentError: Error, Equatable, Sendable {
        public var message: String
        public init(_ message: String) { self.message = message }
        public var forModel: JSONValue { ["error": .string(message)] }
    }

    /// 检查 submit_papers 的参数。
    public static func parsePapers(_ input: JSONValue, fallbackTitle: String) -> Swift.Result<CompilationPlanner.PaperList, ArgumentError> {
        guard let items = input["papers"]?.arrayValue else {
            return .failure(ArgumentError("papers 必须是数组，每项有 title、short、year"))
        }
        var seen = Set<String>()
        var papers: [PaperPlan] = []
        var problems: [String] = []
        for (index, item) in items.enumerated() {
            let title = item["title"]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let year = item["year"]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            guard !title.isEmpty else { problems.append("第 \(index + 1) 项没有 title"); continue }
            guard seen.insert(title).inserted else { continue }
            if year.range(of: #"^\d{4}$"#, options: .regularExpression) == nil {
                problems.append("\(title) 的 year 要写成四位年份")
                continue
            }
            let short = item["short"]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            papers.append(PaperPlan(title: title, shortTitle: short, year: year))
        }
        if !problems.isEmpty { return .failure(ArgumentError(problems.joined(separator: "；") + "。请改正后重新调用 submit_papers。")) }
        guard !papers.isEmpty else { return .failure(ArgumentError("papers 是空的。没有找到符合要求的试卷时，直接用文字说明原因，不要调用 submit_papers。")) }
        let title = input["title"]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return .success(CompilationPlanner.PaperList(
            title: title.isEmpty ? fallbackTitle : String(title.prefix(30)),
            subject: Subject.normalize(input["subject"]?.stringValue ?? ""),
            papers: papers
        ))
    }

    /// 整理的结果：标题、题目顺序（编号）和每道题的组名。
    public struct Arrangement: Sendable, Equatable {
        public var title: String
        public var order: [String]
        /// 编号 → 组名。不分组时为空。
        public var groups: [String: String]
    }

    /// 检查 arrange 的参数。ids 是现在的顺序；漏掉的题按原来的顺序接在最后。
    public static func parseArrangement(_ input: JSONValue, ids: [String], fallbackTitle: String) -> Swift.Result<Arrangement, ArgumentError> {
        let known = Set(ids)
        var order: [String] = []
        var groups: [String: String] = [:]
        var unknown: [String] = []
        var repeated: [String] = []
        func add(_ id: String, group: String?) {
            let id = id.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
            guard known.contains(id) else { unknown.append(id); return }
            guard !order.contains(id) else { repeated.append(id); return }
            order.append(id)
            if let group { groups[id] = group }
        }
        if let list = input["groups"]?.arrayValue, !list.isEmpty {
            for group in list {
                let name = group["name"]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                for item in group["items"]?.arrayValue ?? [] {
                    if let id = item.stringValue { add(id, group: name.isEmpty ? nil : String(name.prefix(30))) }
                }
            }
        } else {
            for item in input["order"]?.arrayValue ?? [] {
                if let id = item.stringValue { add(id, group: nil) }
            }
        }
        if !unknown.isEmpty {
            return .failure(ArgumentError("没有这些编号：\(unknown.joined(separator: "、"))。只能用列表里的编号。"))
        }
        if !repeated.isEmpty {
            return .failure(ArgumentError("这些编号出现了不止一次：\(repeated.joined(separator: "、"))。每道题只能出现一次。"))
        }
        guard !order.isEmpty else { return .failure(ArgumentError("order 和 groups 都是空的，至少给一个。")) }
        order += ids.filter { !order.contains($0) }
        let title = input["title"]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return .success(Arrangement(title: title.isEmpty ? fallbackTitle : String(title.prefix(30)), order: order, groups: groups))
    }

    // MARK: - 获取的结果

    /// fetch_question 的结果。
    public enum FetchStatus: String, Sendable {
        case complete
        case imagesMissing = "images_missing"
        case notFound = "not_found"
        case tooLong = "too_long"
        case refused
        case failed

        /// 调用记录里的说法。
        public var label: String {
            switch self {
            case .complete: "完整"
            case .imagesMissing: "有图未能获取"
            case .notFound: "找不到这几个字"
            case .tooLong: "像是整卷"
            case .refused: "网站拒绝访问"
            case .failed: "下载失败"
            }
        }

        /// 下载网页时的 HTTP 状态：拒绝访问还是别的失败。
        public static func forHTTP(_ status: Int) -> FetchStatus {
            [401, 403, 405, 429, 451].contains(status) ? .refused : .failed
        }
    }

    /// 两次获取哪个更好：完整 > 有图未能获取 > 其他。
    public static func isBetter(_ new: ExamQuestionStatus, than old: ExamQuestionStatus?) -> Bool {
        func rank(_ status: ExamQuestionStatus?) -> Int {
            switch status {
            case .complete: 3
            case .imagesMissing: 2
            case .notFetched: 1
            case nil: 0
            }
        }
        return rank(new) > rank(old)
    }

    /// 交给模型核对的题目文字：图片写成 [图1] [图2]…，太长时截断。
    public static func textForModel(_ markdown: String, limit: Int = questionTextLimit) -> String {
        let pattern = try! NSRegularExpression(pattern: #"!\[\]\((sa-asset|sa-image):[^)]*\)"#)
        let ns = markdown as NSString
        var result = ""
        var cursor = 0
        var count = 0
        for match in pattern.matches(in: markdown, range: NSRange(location: 0, length: ns.length)) {
            result += ns.substring(with: NSRange(location: cursor, length: match.range.location - cursor))
            count += 1
            result += "[图\(count)]"
            cursor = match.range.location + match.range.length
        }
        result += ns.substring(from: cursor)
        return result.count > limit ? String(result.prefix(limit)) + "……" : result
    }

    /// 同一份试卷里题号是不是同一道：去掉"第""题"和空格，"18-20"和"18～20"算一样。
    public static func sameNumber(_ a: String, _ b: String) -> Bool {
        normalizeNumber(a) == normalizeNumber(b)
    }

    public static func normalizeNumber(_ number: String) -> String {
        number
            .trimmingCharacters(in: CharacterSet(charactersIn: "第题 "))
            .replacingOccurrences(of: #"\s*[～~\-—–至]\s*"#, with: "～", options: .regularExpression)
            .replacingOccurrences(of: " ", with: "")
    }

    // MARK: - 找寻

    /// 找寻工具的一条结果。
    public struct SearchResult: Sendable, Equatable {
        public var title: String
        public var url: String
        public var snippet: String

        public init(title: String, url: String, snippet: String) {
            self.title = title
            self.url = url
            self.snippet = snippet
        }

        public var json: JSONValue { ["title": .string(title), "url": .string(url), "snippet": .string(snippet)] }
    }

    /// 能不能直接调 DeepSeek 的 Search API 和 Fetch API：只有 DeepSeek 官方地址可以。返回接口的根地址。
    public static func deepSeekToolsBase(kind: ProviderKind, baseURL: String) -> URL? {
        guard kind == .openAICompatible,
              let url = URL(string: baseURL.trimmingCharacters(in: .whitespacesAndNewlines)),
              url.host()?.lowercased() == "api.deepseek.com"
        else { return nil }
        return URL(string: "https://api.deepseek.com/v1/tools")
    }

    /// 解析 Search API 的返回。
    public static func parseSearchAPI(_ data: Data) -> [SearchResult] {
        guard let value = try? JSONDecoder().decode(JSONValue.self, from: data) else { return [] }
        return (value["results"]?.arrayValue ?? []).compactMap { item in
            guard let url = item["url"]?.stringValue, !url.isEmpty else { return nil }
            let snippet = item["snippet"]?.stringValue ?? item["summary"]?.stringValue ?? ""
            return SearchResult(title: item["title"]?.stringValue ?? "", url: url, snippet: String(snippet.prefix(300)))
        }
    }

    /// 没有 Search API 时的找寻：同一个模型另发一次只开服务商自带搜索的请求（见 ADR-0011）。
    public static func searchRequest(model: String, query: String, dialect: WebSearchDialect) -> ChatRequest {
        ChatRequest(
            model: model,
            systemPrompt: "你是搜索助手。搜索用户给的词，只输出一个 JSON 数组，最多 8 项：[{\"title\":\"…\",\"url\":\"…\",\"snippet\":\"一句话摘要\"}]。只列搜索结果里真实出现的网页，不要编造网址，不要其他文字。",
            messages: [ChatMessage(role: .user, text: query)],
            webSearch: true,
            webSearchDialect: dialect
        )
    }

    /// 解析搜索子请求的回答；模型没按格式回答时，用流里的搜索结果和引用。
    public static func parseSearchReply(_ text: String, fallback: [WebSource]) -> [SearchResult] {
        var results: [SearchResult] = []
        if let start = text.firstIndex(of: "["), let end = text.lastIndex(of: "]"), start < end,
           let items = JSONValue.parse(String(text[start...end]))?.arrayValue {
            results = items.compactMap { item in
                guard let url = item["url"]?.stringValue, url.hasPrefix("http") else { return nil }
                return SearchResult(title: item["title"]?.stringValue ?? "", url: url, snippet: item["snippet"]?.stringValue ?? "")
            }
        }
        if results.isEmpty {
            var seen = Set<String>()
            results = fallback.filter { seen.insert($0.url).inserted }.map { SearchResult(title: $0.title, url: $0.url, snippet: "") }
        }
        return Array(results.prefix(8))
    }
}

/// 一份试卷的工具循环有没有进展：连续 `CompilationTools.maxCallsWithoutProgress` 次没有新进展就该结束了。
public struct PaperProgress: Sendable {
    public private(set) var callsWithoutProgress = 0
    private var hosts: Set<String> = []

    public init() {}

    /// 记一次调用。newHost：这次读到了内容的网站；newQuestion：这次取到了新题或更完整的结果。
    /// 返回 true 表示已经连续太多次没有进展。
    public mutating func record(host: String? = nil, newQuestion: Bool = false) -> Bool {
        var progressed = newQuestion
        if let host, hosts.insert(host.lowercased()).inserted { progressed = true }
        callsWithoutProgress = progressed ? 0 : callsWithoutProgress + 1
        return callsWithoutProgress >= CompilationTools.maxCallsWithoutProgress
    }
}
