import StudyKit
import SwiftData
import SwiftUI

/// 知识卡和关联的读写（第十版）。关联单独存一张表、用 ID 指向两头（docs/adr/0015），所以删卡、加关联、删关联都走这里。
@MainActor
enum ConceptCardStore {
    // MARK: - 读

    static func allCards(in context: ModelContext) -> [ConceptCard] {
        (try? context.fetch(FetchDescriptor<ConceptCard>(sortBy: [SortDescriptor(\.updatedAt, order: .reverse)]))) ?? []
    }

    static func allLinks(in context: ModelContext) -> [ConceptLink] {
        (try? context.fetch(FetchDescriptor<ConceptLink>())) ?? []
    }

    /// 尚未拆卡的资料保留原文入口。
    static func hasOriginalContent(_ note: ResearchNote) -> Bool {
        !note.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    static func originalNote(for card: ConceptCard, in notes: [ResearchNote]) -> ResearchNote? {
        notes.first { $0.id == card.noteID && hasOriginalContent($0) }
    }

    static func edge(_ link: ConceptLink) -> LinkEdge? {
        guard let from = link.fromID, let to = link.toID else { return nil }
        return LinkEdge(from: from, to: to, kind: link.kind)
    }

    /// 还在用的关联（不含用户删掉的模型关联）。
    static func activeEdges(_ links: [ConceptLink]) -> [LinkEdge] {
        links.filter { !$0.dismissed }.compactMap(edge)
    }

    static func candidates(_ cards: [ConceptCard]) -> [ConceptCardWriter.Candidate] {
        cards.map { .init(id: $0.id, title: $0.title, subject: $0.subject, topic: $0.topic, updatedAt: $0.updatedAt) }
    }

    /// 一张卡的关联，按弹窗里的分组顺序：前置、后续、对比、应用、依据。
    struct Neighbor: Identifiable {
        let link: ConceptLink
        let card: ConceptCard
        /// 从这张卡看过去的称呼，例如"前置"。
        let label: String
        var id: UUID { link.id }
    }

    static let labelOrder = ["前置", "后续", "对比", "应用", "依据"]

    static func neighbors(of card: ConceptCard, cards: [ConceptCard], links: [ConceptLink]) -> [Neighbor] {
        let byID = Dictionary(cards.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        return links.filter { !$0.dismissed }.compactMap { link in
            if link.fromID == card.id, let other = link.toID.flatMap({ byID[$0] }) {
                return Neighbor(link: link, card: other, label: link.kind.label(fromSide: true))
            }
            if link.toID == card.id, let other = link.fromID.flatMap({ byID[$0] }) {
                return Neighbor(link: link, card: other, label: link.kind.label(fromSide: false))
            }
            return nil
        }
        .sorted { (labelOrder.firstIndex(of: $0.label) ?? 9) < (labelOrder.firstIndex(of: $1.label) ?? 9) }
    }

    // MARK: - 保存整理结果

    /// 原资料 ID 继续作为卡片分组 ID；新卡和关联保存成功后不再保留原资料。
    /// 返回分组 ID，避免预览持有已经删除的 ResearchNote。和旧卡的关联只留同一科目的。
    @discardableResult
    static func save(
        _ draft: ConceptCardWriter.Draft,
        candidates: [ConceptCardWriter.Candidate],
        modelName: String,
        conversationID: UUID?,
        into originalID: UUID? = nil,
        context: ModelContext,
        persist: (ModelContext) throws -> Void = { try $0.save() }
    ) throws -> UUID {
        try Task.checkCancellation()
        guard !draft.cards.isEmpty else { throw OriginalCleanupError.noCards }
        let groupID = originalID ?? UUID()
        let storedCards = try context.fetch(FetchDescriptor<ConceptCard>())
        let existing: ResearchNote?
        if let originalID {
            existing = try context.fetch(FetchDescriptor<ResearchNote>(predicate: #Predicate { $0.id == originalID })).first
            let alreadySaved = storedCards.filter { $0.noteID == originalID }
            if !alreadySaved.isEmpty {
                if let existing { try removeOriginals([(existing, alreadySaved)], context: context, persist: persist) }
                return groupID
            }
            guard existing != nil else { throw OriginalCleanupError.missingOriginal }
        } else {
            existing = nil
        }
        // 先保存调用前的编辑，后续失败只回滚本次拆卡，不丢其他页面的待保存内容。
        try persist(context)
        let subject = existing?.subject ?? draft.subject ?? .other
        let topic = existing.map { $0.topic } ?? (draft.topic.isEmpty ? "未分类" : draft.topic)
        do {
            let cards: [ConceptCard] = draft.cards.map { item in
                let card = ConceptCard(title: item.title, content: item.content)
                card.example = item.example
                card.sources = item.sources
                card.subject = subject
                card.topic = topic
                card.noteID = groupID
                card.sourceConversationID = conversationID ?? existing?.sourceConversationID
                card.modelName = modelName
                context.insert(card)
                return card
            }
            if let existing { preserveOriginalReferences(existing, in: cards) }
            try validateImages(in: cards, context: context)

            // 引用换成 ID。旧卡不是这个科目的、已经被删的，丢掉。
            let liveIDs = Set(storedCards.map(\.id)).union(cards.map(\.id))
            func id(_ ref: ConceptCardWriter.Ref) -> UUID? {
                switch ref {
                case let .new(index): return cards.indices.contains(index) ? cards[index].id : nil
                case let .old(index):
                    guard candidates.indices.contains(index), liveIDs.contains(candidates[index].id),
                          (candidates[index].subject ?? .other) == subject
                    else { return nil }
                    return candidates[index].id
                }
            }
            let proposed = draft.links.compactMap { link -> (LinkEdge, String)? in
                guard let from = id(link.from), let to = id(link.to) else { return nil }
                return (LinkEdge(from: from, to: to, kind: link.kind), link.reason)
            }
            let links = try context.fetch(FetchDescriptor<ConceptLink>())
            let kept = LinkRules.accept(
                proposed.map(\.0),
                knownCards: liveIDs,
                existing: activeEdges(links),
                dismissed: links.filter(\.dismissed).compactMap(edge)
            )
            for index in kept {
                let (edge, reason) = proposed[index]
                context.insert(ConceptLink(from: edge.from, to: edge.to, kind: edge.kind, reason: reason))
            }
            if let existing { context.delete(existing) }
            try Task.checkCancellation()
            try persist(context)
            return groupID
        } catch {
            context.rollback()
            throw error
        }
    }

    // MARK: - 改

    /// 用户手动加一条关联。不能加时返回原因。
    static func addLink(from: ConceptCard, to: ConceptCard, kind: LinkKind, reason: String, context: ModelContext) -> String? {
        let links = allLinks(in: context)
        let edge = LinkEdge(from: from.id, to: to.id, kind: kind)
        // 用户删过的同一条可以再手动加回来：先把那条删过的记录清掉。
        for link in links where link.dismissed {
            if let old = self.edge(link), old.sameLink(as: edge) { context.delete(link) }
        }
        let accepted = LinkRules.accept([edge], knownCards: [from.id, to.id], existing: activeEdges(links), dismissed: [])
        guard !accepted.isEmpty else {
            if activeEdges(links).contains(where: { $0.sameLink(as: edge) }) { return "已经有这条关联了。" }
            return "一张知识卡最多 \(LinkRules.maxPerCard) 条关联。"
        }
        context.insert(ConceptLink(from: from.id, to: to.id, kind: kind, reason: reason.trimmingCharacters(in: .whitespacesAndNewlines), isManual: true))
        try? context.save()
        return nil
    }

    /// 删掉一条关联。模型提出的只做标记，以后模型再提出同一条就忽略。
    static func remove(_ link: ConceptLink, context: ModelContext) {
        if link.isManual {
            context.delete(link)
        } else {
            link.dismissed = true
        }
        try? context.save()
    }

    /// 真正删掉一张知识卡（撤销的 5 秒过后）：连同两头带它的关联。
    /// 原资料已在拆卡保存时删除；旧版无原文容器随最后一张卡清理。
    static func delete(_ card: ConceptCard, context: ModelContext) {
        let id = card.id
        for link in allLinks(in: context) where link.fromID == id || link.toID == id {
            context.delete(link)
        }
        let noteID = card.noteID
        context.delete(card)
        if let noteID {
            let remaining = allCards(in: context).filter { $0.noteID == noteID && $0.id != id }
            if remaining.isEmpty,
               let note = try? context.fetch(FetchDescriptor<ResearchNote>(predicate: #Predicate { $0.id == noteID })).first {
                if hasOriginalContent(note) {
                    note.isCardBased = false
                    note.updatedAt = .now
                } else {
                    context.delete(note)
                }
            }
        }
        try? context.save()
    }

    /// 关系图里拖完一个节点：记住位置。
    static func pin(_ card: ConceptCard, at point: MapPoint, context: ModelContext) {
        card.pinnedPosition = point
        try? context.save()
    }

    // MARK: - 颜色

    /// 知识点的颜色：同一个科目里按知识点名字排序后轮流取色，同一张图里每次都一样。
    static let palette: [Color] = [
        Color(red: 0.30, green: 0.56, blue: 1.00), Color(red: 0.20, green: 0.78, blue: 0.55),
        Color(red: 1.00, green: 0.62, blue: 0.04), Color(red: 0.75, green: 0.45, blue: 1.00),
        Color(red: 1.00, green: 0.42, blue: 0.48), Color(red: 0.25, green: 0.78, blue: 0.85),
        Color(red: 0.85, green: 0.72, blue: 0.25), Color(red: 0.55, green: 0.62, blue: 0.70),
    ]

    static func topicColors(_ topics: [String]) -> [String: Color] {
        let sorted = Array(Set(topics)).sorted { $0.localizedStandardCompare($1) == .orderedAscending }
        return Dictionary(uniqueKeysWithValues: sorted.enumerated().map { ($1, palette[$0 % palette.count]) })
    }
}
