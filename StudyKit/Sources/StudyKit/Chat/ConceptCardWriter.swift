import Foundation

/// 把会话、一条回答或一份旧资料整理成知识卡和关联（第十版）。准备发给模型的材料，解析模型输出的 JSON。
/// 提示词在 `Prompts/cards.md`，tools/eval 的 `--cards` 读同一份。
public enum ConceptCardWriter {
    /// 整理说明，接在内置格式规则后面（不带组件规则，知识卡里不放组件）。
    public static let instructions = SystemPrompt.load("cards")

    /// 一次最多发给模型几张已有的知识卡。
    public static let candidateLimit = 80
    /// 一次最多留几张新卡。
    public static let cardLimit = 10

    /// 发给模型的一张已有知识卡。
    public struct Candidate: Sendable, Equatable {
        public var id: UUID
        public var title: String
        public var subject: Subject?
        public var topic: String
        public var updatedAt: Date

        public init(id: UUID, title: String, subject: Subject?, topic: String, updatedAt: Date) {
            self.id = id
            self.title = title
            self.subject = subject
            self.topic = topic
            self.updatedAt = updatedAt
        }
    }

    /// 卡片的指代：新卡在 `cards` 里的位置，或者旧卡在候选列表里的位置。
    public enum Ref: Sendable, Equatable, Hashable {
        case new(Int)
        case old(Int)
    }

    public struct DraftCard: Sendable, Equatable {
        public var title: String
        /// 引用已经换成角标。
        public var content: String
        public var example: String
        /// 这张卡用到的出处，编号和它的角标一致。
        public var sources: [WebSource]
    }

    public struct DraftLink: Sendable, Equatable {
        public var from: Ref
        public var to: Ref
        public var kind: LinkKind
        public var reason: String
    }

    public struct Draft: Sendable, Equatable {
        public var title: String
        public var subject: Subject?
        public var topic: String
        public var cards: [DraftCard]
        /// 至少有一头是新卡；指向不存在的卡、种类不对的已经去掉。重复和每张卡的上限由 `LinkRules` 在保存时处理。
        public var links: [DraftLink]
    }

    public struct ParseError: Error, Equatable, LocalizedError {
        public var message: String
        public var errorDescription: String? { message }
    }

    // MARK: - 发给模型

    /// 选出发给模型的已有知识卡：不超过上限时全部发；超过时先发同一知识点的，再按最近更新补满。
    /// 已知科目时（拆旧资料）只发同一科目的。
    public static func selectCandidates(_ all: [Candidate], subject: Subject? = nil, topic: String = "") -> [Candidate] {
        var pool = all
        if let subject { pool = pool.filter { ($0.subject ?? .other) == subject } }
        pool.sort { $0.updatedAt > $1.updatedAt }
        guard pool.count > candidateLimit else { return pool }
        let sameTopic = topic.isEmpty ? [] : pool.filter { $0.topic == topic }
        var result = Array(sameTopic.prefix(candidateLimit))
        for candidate in pool where result.count < candidateLimit && !result.contains(where: { $0.id == candidate.id }) {
            result.append(candidate)
        }
        return result
    }

    /// 发给模型的那条用户消息：整理材料（`ResearchNoteWriter.prepare` 的结果）加上已有的知识卡。
    public static func message(material: String, candidates: [Candidate]) -> String {
        var text = "【要整理的材料】\n" + material
        if candidates.isEmpty {
            text += "\n\n【已有的知识卡】\n（还没有）"
        } else {
            let lines = candidates.enumerated().map { index, card in
                let meta = [card.subject?.rawValue ?? "", card.topic].filter { !$0.isEmpty }.joined(separator: " · ")
                return "旧\(index + 1) \(card.title)" + (meta.isEmpty ? "" : "（\(meta)）")
            }
            text += "\n\n【已有的知识卡】\n" + lines.joined(separator: "\n")
        }
        return text
    }

    public static func request(model: String, material: String, candidates: [Candidate], reasoningEffort: ReasoningEffort? = nil) -> ChatRequest {
        ChatRequest(
            model: model,
            systemPrompt: SystemPrompt.compose(customInstructions: "", conversationInstructions: instructions, simpleMode: true),
            messages: [ChatMessage(role: .user, text: message(material: material, candidates: candidates))],
            reasoningEffort: reasoningEffort
        )
    }

    /// 解析失败后的重试：只让模型修好这个 JSON。
    public static func repairRequest(model: String, raw: String, error: String) -> ChatRequest {
        let user = """
        下面这段 JSON 没能解析，原因：\(error)

        \(String(raw.prefix(12000)))

        请改正格式后重新输出，内容不要变。只输出一个 ```json 代码块，前后不要有任何文字。
        """
        return ChatRequest(
            model: model,
            systemPrompt: "你负责修正 JSON 格式。字符串用双引号，反斜杠写两个，不要注释和多余的逗号。",
            messages: [ChatMessage(role: .user, text: user)]
        )
    }

    // MARK: - 解析

    /// 解析模型的输出。`sources` 是整理材料时统一编号的出处，`candidateCount` 是发出去的旧卡数。
    public static func parse(_ raw: String, sources: [WebSource], candidateCount: Int, fallbackTitle: String) throws -> Draft {
        guard let json = jsonText(in: raw) else { throw ParseError(message: "没有找到 JSON") }
        let object: Any
        do {
            object = try JSONSerialization.jsonObject(with: Data(json.utf8))
        } catch {
            throw ParseError(message: "JSON 格式有误：\((error as NSError).userInfo[NSDebugDescriptionErrorKey] as? String ?? error.localizedDescription)")
        }
        guard let root = object as? [String: Any] else { throw ParseError(message: "最外层应该是一个对象") }
        guard let rawCards = root["cards"] as? [[String: Any]] else { throw ParseError(message: "缺少 cards 数组") }

        var cards: [DraftCard] = []
        var keys: [String: Int] = [:]
        for item in rawCards {
            guard cards.count < cardLimit else { break }
            let title = string(item["title"])
            let content = string(item["content"])
            guard !title.isEmpty, !content.isEmpty else { continue }
            let cited = cite(content: content, example: string(item["example"]), sources: sources)
            let key = string(item["key"])
            if !key.isEmpty, keys[key] == nil { keys[key] = cards.count }
            cards.append(DraftCard(title: String(title.prefix(20)), content: cited.content, example: cited.example, sources: cited.sources))
        }
        guard !cards.isEmpty else { throw ParseError(message: "cards 里没有一张有标题和内容的卡") }

        func ref(_ value: Any?) -> Ref? {
            let text = string(value)
            if let index = keys[text] { return .new(index) }
            let digits = text.filter(\.isNumber)
            let isOld = text.hasPrefix("旧") || text.lowercased().hasPrefix("old")
            if isOld, let n = Int(digits), n >= 1, n <= candidateCount { return .old(n - 1) }
            return nil
        }
        var links: [DraftLink] = []
        for item in root["links"] as? [[String: Any]] ?? [] {
            guard let from = ref(item["from"]), let to = ref(item["to"]), from != to,
                  let kind = LinkKind.parse(string(item["kind"]))
            else { continue }
            if case .old = from, case .old = to { continue }
            links.append(DraftLink(from: from, to: to, kind: kind, reason: String(string(item["reason"]).prefix(40))))
        }

        let title = string(root["title"])
        let topic = string(root["topic"])
        return Draft(
            title: title.isEmpty ? fallbackTitle : String(title.prefix(30)),
            subject: Subject.normalize(string(root["subject"])),
            topic: String(topic.prefix(20)),
            cards: cards,
            links: links
        )
    }

    /// 回复里的 JSON：优先取 ```json 代码块，没有时取第一个 { 到最后一个 }。
    static func jsonText(in raw: String) -> String? {
        let lines = raw.components(separatedBy: "\n")
        if let start = lines.firstIndex(where: { $0.trimmingCharacters(in: .whitespaces).hasPrefix("```") }) {
            if let end = lines[(start + 1)...].firstIndex(where: { $0.trimmingCharacters(in: .whitespaces).hasPrefix("```") }) {
                let body = lines[(start + 1)..<end].joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
                if body.hasPrefix("{") { return body }
            }
        }
        guard let open = raw.firstIndex(of: "{"), let close = raw.lastIndex(of: "}"), open < close else { return nil }
        return String(raw[open...close])
    }

    private static func string(_ value: Any?) -> String {
        (value as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }

    /// 一张卡里的 [n] 换成角标，只留这张卡用到的出处。没有引用时这张卡没有出处。
    static func cite(content: String, example: String, sources: [WebSource]) -> (content: String, example: String, sources: [WebSource]) {
        let pattern = try! NSRegularExpression(pattern: #"(?<!\[)\[\d{1,3}\](?![\(\]])"#)
        let joined = content + "\n\u{1}\n" + example
        guard !sources.isEmpty,
              pattern.firstMatch(in: joined, range: NSRange(location: 0, length: (joined as NSString).length)) != nil
        else { return (content, example, []) }
        let cited = ResearchNoteWriter.citeSources(in: joined, sources: sources)
        let parts = cited.content.components(separatedBy: "\n\u{1}\n")
        guard parts.count == 2, cited.content != joined else { return (content, example, []) }
        return (parts[0], parts[1], cited.sources)
    }
}
