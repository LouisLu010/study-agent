import Foundation

/// 汇编的两步请求（列试卷、在一份试卷里找题）和相关的解析、排序、估价（见 docs/adr/0013）。
public enum CompilationPlanner {
    // MARK: - 列试卷

    public struct PaperList: Sendable, Equatable {
        public var title: String
        public var subject: Subject?
        public var papers: [PaperPlan]
    }

    public static func listPapersRequest(model: String, request: String, reasoningEffort: ReasoningEffort?, today: Date = .now) -> ChatRequest {
        ChatRequest(
            model: model,
            systemPrompt: """
            你是一名教研员，负责整理考试题目汇编。今天是 \(dateText(today))。
            用户会说要哪类题。请联网搜索，列出符合要求、已经公开的真实试卷（考试类型不限：高考、中考、模拟考、期中期末考都可以，按用户的要求来）。
            要求：
            1. 只列确实存在、已经考过的试卷，不要编造。每一份都要先搜索核实它当年确实存在（各地每年用的试卷会变，例如有的年份起不再有某种全国卷），核实不了的不要列。每份试卷单独一项，不要重复。
            2. "近 N 年"按今天往前算；用户没说范围时，列最近 3 年最主要的几份。
            3. 只输出一个 JSON 对象，不要其他文字：
            {"title":"汇编标题，不超过 20 个字","subject":"数学、物理、化学、生物、语文、英语、其他 之一","papers":[{"title":"试卷全称","short":"简称，例如 新课标Ⅰ卷、北京卷、海淀一模","year":"2025"}]}
            """,
            messages: [ChatMessage(role: .user, text: request)],
            reasoningEffort: reasoningEffort,
            webSearch: true
        )
    }

    public static func parsePaperList(_ raw: String, fallbackTitle: String) -> PaperList? {
        guard let object = jsonObject(in: raw), let items = object["papers"] as? [[String: Any]] else { return nil }
        var seen = Set<String>()
        let papers = items.compactMap { item -> PaperPlan? in
            let title = string(item["title"])
            guard !title.isEmpty, seen.insert(title).inserted else { return nil }
            return PaperPlan(title: title, shortTitle: string(item["short"]), year: string(item["year"]))
        }
        let title = string(object["title"])
        return PaperList(
            title: title.isEmpty ? fallbackTitle : String(title.prefix(30)),
            subject: Subject.normalize(string(object["subject"])),
            papers: papers
        )
    }

    // MARK: - 在一份试卷里找题

    /// 模型找到的一道题：题号、定位用的几个字、候选网页。
    public struct FoundQuestion: Sendable, Equatable {
        public var number: String
        public var anchor: String
        public var lastAnchor: String
        public var urls: [String]
    }

    public static func findQuestionsRequest(
        model: String,
        request: String,
        paper: PaperPlan,
        onlyNumber: String? = nil,
        reasoningEffort: ReasoningEffort?
    ) -> ChatRequest {
        let target = onlyNumber.map { "只找这份试卷的第 \($0) 题。" } ?? "找出这份试卷里所有符合要求的题。"
        return ChatRequest(
            model: model,
            systemPrompt: """
            你是一名严谨的教研员，负责在网上找到考试原题所在的网页。必须联网搜索并打开网页核对。
            要求：
            1. 优先找"每道题单独一个页面"的题目详情页，例如 gaotu.cn/topic/…、zujuan.21cnjy.com/question/detail/…、菁优网的试题页；其次才是整卷的资料页。不要选需要下载文档、登录或付费才能看到题目的页面，也不要选公众号文章和小红书。
            2. 每道题尽量给出 3 个以上不同网站的候选网址，按可靠程度排序。只列你实际打开过、确认是这道题的网址。
            3. anchor 是题干开头约 15 个字，last_anchor 是最后一问开头约 10 个字，都逐字照抄网页上的文字，用来在网页里定位这道题。
            4. 题型和内容都要符合要求，例如要"大题"就不要选择题。这份试卷里没有符合要求的题，就返回空数组，不要编造。
            5. 只输出一个 JSON 对象，不要其他文字：
            {"questions":[{"number":"题号","anchor":"…","last_anchor":"…","urls":["…"]}]}
            """,
            messages: [ChatMessage(role: .user, text: "要求：\(request)\n试卷：\(paper.title)\n\(target)")],
            reasoningEffort: reasoningEffort,
            webSearch: true
        )
    }

    public static func parseFoundQuestions(_ raw: String) -> [FoundQuestion]? {
        guard let object = jsonObject(in: raw), let items = object["questions"] as? [[String: Any]] else { return nil }
        return items.compactMap { item in
            let anchor = string(item["anchor"])
            let urls = (item["urls"] as? [Any] ?? []).map { string($0) }.filter { $0.hasPrefix("http") }
            guard !anchor.isEmpty else { return nil }
            return FoundQuestion(
                number: string(item["number"]).trimmingCharacters(in: CharacterSet(charactersIn: "第题 ")),
                anchor: anchor,
                lastAnchor: string(item["last_anchor"]),
                urls: urls
            )
        }
    }

    // MARK: - 网站

    /// 已知会拒绝程序访问、或者拿不到正文的网站，不去下载。
    static let unusableHosts = ["zujuan.xkw.com", "www.zxxk.com", "51jiaoxi.com", "doc.21cnjy.com", "mp.weixin.qq.com", "xiaohongshu.com", "douyin.com", "bilibili.com"]
    /// 取图效果最好的网站排在前面。
    static let preferredHosts = ["gaotu.cn", "zujuan.21cnjy.com"]

    /// 按能不能取到原题排序，去掉已知不能用的网站；http 换成 https（App 只允许 https）。
    public static func orderedCandidates(_ urls: [String]) -> [URL] {
        var seen = Set<String>()
        let parsed = urls.compactMap { raw -> URL? in
            var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            if text.hasPrefix("http://") { text = "https://" + text.dropFirst(7) }
            guard let url = URL(string: text), let host = url.host()?.lowercased(),
                  !unusableHosts.contains(where: { host == $0 || host.hasSuffix("." + $0) }),
                  seen.insert(url.absoluteString).inserted
            else { return nil }
            return url
        }
        func rank(_ url: URL) -> Int {
            let host = url.host()?.lowercased() ?? ""
            if let index = preferredHosts.firstIndex(where: { host == $0 || host.hasSuffix("." + $0) }) {
                // 21 世纪教育网只有题目详情页能取到图。
                if preferredHosts[index] == "zujuan.21cnjy.com", !url.path().contains("/question/detail") { return 10 }
                return index
            }
            return 5
        }
        return parsed.enumerated().sorted { (rank($0.element), $0.offset) < (rank($1.element), $1.offset) }.map(\.element)
    }

    /// 网站的中文名，用于"网站解析"的标注。
    public static func siteName(for url: URL) -> String {
        let host = url.host()?.lowercased() ?? ""
        let names = [("gaotu.cn", "高途"), ("21cnjy.com", "21 世纪教育网"), ("jyeoo.com", "菁优网"), ("xkw.com", "学科网"), ("zxxk.com", "学科网"), ("51jiaoxi.com", "51 教习")]
        return names.first { host == $0.0 || host.hasSuffix("." + $0.0) }?.1 ?? host.replacingOccurrences(of: "www.", with: "")
    }

    // MARK: - 题目内容

    /// 把 `sa-image:N` 换成 App 里保存的图片 `sa-asset:<id>`；没下载到的图换成提示文字。
    public static func assemble(_ markdown: String, assets: [Int: UUID]) -> String {
        let pattern = try! NSRegularExpression(pattern: #"!\[\]\(sa-image:(\d+)( "[^"]*")?\)"#)
        let ns = markdown as NSString
        var result = ""
        var cursor = 0
        for match in pattern.matches(in: markdown, range: NSRange(location: 0, length: ns.length)) {
            result += ns.substring(with: NSRange(location: cursor, length: match.range.location - cursor))
            let index = Int(ns.substring(with: match.range(at: 1))) ?? -1
            let title = match.range(at: 2).location == NSNotFound ? "" : ns.substring(with: match.range(at: 2))
            if let id = assets[index] {
                result += "![](sa-asset:\(id.uuidString)\(title))"
            } else {
                result += "［图未能获取］"
            }
            cursor = match.range.location + match.range.length
        }
        result += ns.substring(from: cursor)
        return result
    }

    /// 例如"2025 · 北京卷 · 第 17 题"。
    public static func label(year: String, paper: String, number: String) -> String {
        var parts: [String] = []
        if !year.isEmpty { parts.append(year) }
        if !paper.isEmpty { parts.append(paper) }
        if !number.isEmpty { parts.append("第 \(number) 题") }
        return parts.joined(separator: " · ")
    }

    // MARK: - 估价

    /// 一次联网查题的大致用量，来自 A0 试验（deepseek-flash 深度搜索）：约 7 万输入、5 千输出、8 次搜索。
    static let tokensPerSearchInput = 70_000
    static let tokensPerSearchOutput = 5_000
    static let searchesPerSearch = 8

    /// 列试卷一次加上每份试卷查一次的估算费用（人民币）。没有价格时返回 nil。
    public static func estimateCostCNY(papers: Int, price: ModelPrice?, usdToCNY: Double) -> Double? {
        guard let price else { return nil }
        let one = price.costCNY(
            inputTokens: tokensPerSearchInput,
            outputTokens: tokensPerSearchOutput,
            webSearches: searchesPerSearch,
            usdToCNY: usdToCNY
        )
        return one * Double(papers)
    }

    // MARK: - 工具

    /// 取出文字里的第一个 JSON 对象，允许外面包着代码块或说明。
    static func jsonObject(in raw: String) -> [String: Any]? {
        guard let start = raw.firstIndex(of: "{"), let end = raw.lastIndex(of: "}"), start < end else { return nil }
        return try? JSONSerialization.jsonObject(with: Data(raw[start...end].utf8)) as? [String: Any]
    }

    static func string(_ value: Any?) -> String {
        if let text = value as? String { return text.trimmingCharacters(in: .whitespacesAndNewlines) }
        if let number = value as? NSNumber { return number.stringValue }
        return ""
    }

    static func dateText(_ date: Date) -> String {
        let components = Calendar(identifier: .gregorian).dateComponents([.year, .month, .day], from: date)
        return "\(components.year ?? 0) 年 \(components.month ?? 0) 月 \(components.day ?? 0) 日"
    }
}
