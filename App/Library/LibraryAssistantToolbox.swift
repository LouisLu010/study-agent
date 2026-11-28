import CryptoKit
import Foundation
import StudyKit
import SwiftData

/// 模型只提交编辑建议；读取授权、版本、引用和关系都在本机核对后才保存。
@MainActor
final class LibraryAssistantToolbox {
    private let context: ModelContext
    private let modelName: String
    private let onChange: @MainActor (LibraryAssistantChange) -> Void
    private var cardRevisions: [UUID: String] = [:]
    private var noteRevisions: [UUID: String] = [:]
    private var readGroups: [[UUID]: [String]] = [:]
    private var readLinks: [UUID: [UUID: String]] = [:]
    private typealias Failure = LibraryAssistantTools.ArgumentError

    init(context: ModelContext, modelName: String, onChange: @escaping @MainActor (LibraryAssistantChange) -> Void = { _ in }) {
        self.context = context
        self.modelName = modelName
        self.onChange = onChange
    }

    func execute(_ call: ToolCall) async throws -> ToolLoop.Outcome {
        try Task.checkCancellation()
        let value: JSONValue
        switch try LibraryAssistantTools.parse(call) {
        case let .listCards(query, subject, offset, limit):
            let cards = try allCards().filter {
                (subject == nil || ($0.subject ?? .other) == subject)
                    && matches(query, in: [$0.title, $0.topic, $0.content, $0.example])
            }
            value = page(cards.map { card in
                ["id": .string(card.id.uuidString), "title": .string(card.title),
                 "subject": .string(card.subjectRaw), "topic": .string(card.topic)]
            }, key: "cards", offset: offset, limit: limit)
        case let .readCards(ids):
            let cards = try findCards(ids)
            try checkReadSize(cards.map { $0.content + $0.example + $0.sourcesJSON }.joined())
            try context.save()
            let links = try allLinks()
            var values: [JSONValue] = []
            for card in cards {
                let revision = digest(cardData(card))
                cardRevisions[card.id] = revision
                readLinks[card.id] = linkValues(links.filter { $0.fromID == card.id || $0.toID == card.id })
                values.append([
                    "id": .string(card.id.uuidString), "title": .string(card.title),
                    "content": .string(card.content), "example": .string(card.example),
                    "subject": .string(card.subjectRaw), "topic": .string(card.topic),
                    "sources": sourceData(card.sources), "revision": .string(revision),
                ])
            }
            readGroups[ids] = cards.map { digest(cardData($0)) }
            value = ["cards": .array(values), "merge_sources": sourceData(mergedSources(cards))]
        case let .updateCards(updates): value = try update(updates)
        case let .mergeCards(request): value = try merge(request)
        case let .listNotes(query, offset, limit):
            let notes = try allNotes().filter { matches(query, in: [$0.title, $0.topic, $0.content]) }
            value = page(notes.map {
                ["id": .string($0.id.uuidString), "title": .string($0.title),
                 "subject": .string($0.subjectRaw), "topic": .string($0.topic)]
            }, key: "notes", offset: offset, limit: limit)
        case let .readNote(id):
            let note = try findNote(id)
            try checkReadSize(note.content + note.sourcesJSON)
            try context.save()
            let revision = digest(noteData(note))
            noteRevisions[id] = revision
            value = ["note": [
                "id": .string(note.id.uuidString), "title": .string(note.title),
                "content": .string(note.content), "subject": .string(note.subjectRaw),
                "topic": .string(note.topic), "sources": sourceData(note.sources), "revision": .string(revision),
            ]]
        case let .organizeNote(request): value = try organize(request)
        }
        return ToolLoop.Outcome(value)
    }

    private func update(_ updates: [LibraryAssistantTools.CardUpdate]) throws -> JSONValue {
        let cards = try findCards(updates.map(\.id))
        for (card, update) in zip(cards, updates) {
            try requireRead(card, revision: update.revision)
            try validateImages(before: card.content + "\n" + card.example, after: update.content + "\n" + update.example)
        }
        try validatePersistedState(cardIDs: Set(cards.map(\.id)))
        let subjects = Dictionary(uniqueKeysWithValues: updates.map { ($0.id, $0.subject?.rawValue ?? "") })
        try validateSubjects(affected: Set(cards.map(\.id)), proposed: subjects)
        let normalizedContents = try updates.map { update in
            let card = cards.first { $0.id == update.id }!
            return (try normalized(update.content, sources: card.sources), try normalized(update.example, sources: card.sources))
        }
        let summary = "已整理 \(cards.count) 张知识卡"
        try mutate(summary: summary) {
            for (index, pair) in zip(cards, updates).enumerated() {
                let (card, update) = pair
                card.title = update.title
                card.content = normalizedContents[index].0
                card.example = normalizedContents[index].1
                card.subject = update.subject
                card.topic = update.topic
                card.updatedAt = .now
            }
            try ConceptCardStore.validateImages(in: cards, context: context)
        }
        for card in cards { cardRevisions.removeValue(forKey: card.id) }
        return ["success": true, "message": .string(summary)]
    }

    private func merge(_ request: LibraryAssistantTools.MergeCards) throws -> JSONValue {
        let cards = try findCards(request.ids)
        for (card, revision) in zip(cards, request.revisions) { try requireRead(card, revision: revision) }
        guard readGroups[request.ids] == request.revisions else {
            throw Failure("合并前请按 ids 顺序一次 read_cards，使用该次返回的 merge_sources 编号。")
        }
        guard let keeper = cards.first,
              cards.allSatisfy({ ($0.subject ?? .other) == (keeper.subject ?? .other) }),
              (request.subject ?? .other) == (keeper.subject ?? .other)
        else { throw Failure("只能合并同一科目的知识卡，合并时请保留原科目。") }
        try validateImages(
            before: cards.map { $0.content + "\n" + $0.example }.joined(separator: "\n"),
            after: request.content + "\n" + request.example
        )
        let ids = Set(request.ids)
        try validatePersistedState(cardIDs: ids)
        let sources = mergedSources(cards)
        let summary = "已将 \(cards.count) 张知识卡合并为「\(request.title)」"
        try mutate(summary: summary) {
            keeper.title = request.title
            keeper.content = try normalized(request.content, sources: sources)
            keeper.example = try normalized(request.example, sources: sources)
            keeper.sources = sources
            keeper.subject = request.subject
            keeper.topic = request.topic
            keeper.updatedAt = .now
            if keeper.sourceConversationID == nil { keeper.sourceConversationID = cards.compactMap(\.sourceConversationID).first }
            try reconnect(ids: ids, to: keeper.id)
            for card in cards.dropFirst() { context.delete(card) }
            try validateSubjects(affected: [keeper.id])
            try ConceptCardStore.validateImages(in: [keeper], context: context)
        }
        for id in ids { cardRevisions.removeValue(forKey: id) }
        return ["success": true, "id": .string(keeper.id.uuidString), "message": .string(summary)]
    }

    private func organize(_ request: LibraryAssistantTools.OrganizeNote) throws -> JSONValue {
        let note = try findNote(request.id)
        guard noteRevisions[note.id] == request.revision, digest(noteData(note)) == request.revision else {
            throw Failure("原资料尚未完整读取或已经变化，请重新 read_note 后整理。")
        }
        guard try !allCards().contains(where: { $0.noteID == note.id }) else {
            throw Failure("这份资料已经有知识卡，请读取并整理现有卡片，避免重复拆卡。")
        }
        try validatePersistedState(noteIDs: [note.id])
        try validateImages(before: note.content, after: request.cards.map { $0.content + "\n" + $0.example }.joined(separator: "\n"))
        let groupID = note.id
        let summary = "已把「\(note.title)」整理为 \(request.cards.count) 张知识卡，并删除原资料"
        try mutate(summary: summary) {
            let cards = try request.cards.map { draft in
                let card = ConceptCard(title: draft.title, content: try normalized(draft.content, sources: note.sources))
                card.example = try normalized(draft.example, sources: note.sources)
                card.sources = note.sources
                card.subject = request.subject
                card.topic = request.topic
                card.noteID = groupID
                card.sourceConversationID = note.sourceConversationID
                card.modelName = modelName
                context.insert(card)
                return card
            }
            try ConceptCardStore.validateImages(in: cards, context: context)
            context.delete(note)
        }
        noteRevisions.removeValue(forKey: groupID)
        return ["success": true, "group_id": .string(groupID.uuidString), "message": .string(summary)]
    }

    /// 每个工具调用作为一次可撤销操作；保存失败不会留下部分写入。
    private func mutate(summary: String, _ action: () throws -> Void) throws {
        try Task.checkCancellation()
        try context.save()
        let before = try LibraryAssistantSnapshot(context: context)
        do {
            try action()
            try Task.checkCancellation()
            let after = try LibraryAssistantSnapshot(context: context)
            try context.save()
            let change = LibraryAssistantChange(before: before, after: after, summary: summary)
            if !change.isEmpty { onChange(change) }
        } catch {
            context.rollback()
            throw error
        }
    }

    /// 重接外部关联，合并后的内部自环删除；重复关联合并说明，保留手动标记。
    private func reconnect(ids: Set<UUID>, to keeper: UUID) throws {
        let links = try allLinks()
        var retained: [ConceptLink] = []
        for link in links {
            guard let from = link.fromID, let to = link.toID else { continue }
            let affected = ids.contains(from) || ids.contains(to)
            if affected {
                link.fromID = ids.contains(from) ? keeper : from
                link.toID = ids.contains(to) ? keeper : to
            }
            guard let edge = ConceptCardStore.edge(link) else { continue }
            if affected && edge.from == edge.to {
                context.delete(link)
                continue
            }
            if let duplicate = retained.first(where: { existing in
                guard let other = ConceptCardStore.edge(existing) else { return false }
                return other.sameLink(as: edge)
            }), edge.from == keeper || edge.to == keeper {
                guard duplicate.dismissed == link.dismissed else {
                    throw Failure("这些卡片的关联存在保留与已删除记录冲突，合并会改变关系，请先处理关联。")
                }
                duplicate.isManual = duplicate.isManual || link.isManual
                if !link.reason.isEmpty, duplicate.reason != link.reason {
                    duplicate.reason = [duplicate.reason, link.reason].filter { !$0.isEmpty }.joined(separator: "\n")
                }
                context.delete(link)
            } else {
                retained.append(link)
            }
        }
        let active = retained.filter { !$0.dismissed }.compactMap(ConceptCardStore.edge)
        guard active.filter({ $0.from == keeper || $0.to == keeper }).count <= LinkRules.maxPerCard else {
            throw Failure("合并后关联超过 \(LinkRules.maxPerCard) 条，无法完整保留；请减少合并范围。")
        }
    }

    private func validateSubjects(affected: Set<UUID>, proposed: [UUID: String] = [:]) throws {
        let cards = Dictionary(try allCards().map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        for link in try allLinks() where !link.dismissed {
            guard let fromID = link.fromID, let toID = link.toID,
                  affected.contains(fromID) || affected.contains(toID)
            else { continue }
            guard let from = cards[fromID], let to = cards[toID],
                  (Subject(rawValue: proposed[fromID] ?? from.subjectRaw) ?? .other)
                    == (Subject(rawValue: proposed[toID] ?? to.subjectRaw) ?? .other)
            else { throw Failure("修改会产生跨科目或失效关联，请把有关联的卡片一起整理到同一科目。") }
        }
    }

    private func validateImages(before: String, after: String) throws {
        let old = Set(CompilationCenter.imageIDs(in: before))
        let new = Set(CompilationCenter.imageIDs(in: after))
        guard old == new else { throw Failure("请保留原内容里的全部 sa-asset 图片引用，不能省略或虚构图片。") }
    }

    private func normalized(_ text: String, sources: [WebSource]) throws -> String {
        guard let content = ResearchNoteWriter.normalizedCitations(in: text, sources: sources) else {
            throw Failure("内容中出现了原来源表之外的出处角标，请只引用读取结果中的来源。")
        }
        return content
    }

    private func requireRead(_ card: ConceptCard, revision: String) throws {
        guard cardRevisions[card.id] == revision, digest(cardData(card)) == revision else {
            throw Failure("卡片尚未完整读取或已经变化，请重新 read_cards 后修改。")
        }
    }

    /// 其他窗口或同步可能已经保存了新版本，而当前上下文仍缓存旧对象。
    /// 只核对本次涉及的卡片、原文及周边关联，允许无关资料继续编辑。
    private func validatePersistedState(cardIDs: Set<UUID> = [], noteIDs: Set<UUID> = []) throws {
        let fresh = ModelContext(context.container)
        fresh.autosaveEnabled = false
        let currentLinks = try allLinks().filter { link in
            link.fromID.map(cardIDs.contains) == true || link.toID.map(cardIDs.contains) == true
        }
        let savedLinks = try fresh.fetch(FetchDescriptor<ConceptLink>()).filter { link in
            link.fromID.map(cardIDs.contains) == true || link.toID.map(cardIDs.contains) == true
        }
        for id in cardIDs {
            guard readLinks[id] == linkValues(savedLinks.filter({ $0.fromID == id || $0.toID == id })) else {
                throw Failure("卡片关联在读取后发生了变化，请重新 read_cards 后操作。")
            }
        }
        let neighbors = Set((currentLinks + savedLinks).flatMap { [$0.fromID, $0.toID].compactMap { $0 } })
        let checkedIDs = cardIDs.union(neighbors)
        func cardValues(_ cards: [ConceptCard]) -> [UUID: String] {
            Dictionary(cards.filter { checkedIDs.contains($0.id) || $0.noteID.map(noteIDs.contains) == true }
                .map { ($0.id, digest(cardData($0))) }, uniquingKeysWith: { first, _ in first })
        }
        func noteValues(_ notes: [ResearchNote]) -> [UUID: String] {
            Dictionary(notes.filter { noteIDs.contains($0.id) }.map { ($0.id, digest(noteData($0))) }, uniquingKeysWith: { first, _ in first })
        }
        guard linkValues(currentLinks) == linkValues(savedLinks),
              try cardValues(allCards()) == cardValues(fresh.fetch(FetchDescriptor<ConceptCard>())),
              try noteValues(allNotes()) == noteValues(fresh.fetch(FetchDescriptor<ResearchNote>()))
        else { throw Failure("这些资料或关联已在其他窗口更新，请重新打开资料页并读取后再整理。") }
    }

    private func linkValues(_ links: [ConceptLink]) -> [UUID: String] {
        Dictionary(links.map { link in
            (link.id, digest([
                "from": link.fromID.map { .string($0.uuidString) } ?? .null,
                "to": link.toID.map { .string($0.uuidString) } ?? .null,
                "kind": .string(link.kindRaw), "reason": .string(link.reason),
                "manual": .bool(link.isManual), "dismissed": .bool(link.dismissed),
                "created": .string(String(link.createdAt.timeIntervalSince1970.bitPattern)),
            ]))
        }, uniquingKeysWith: { first, _ in first })
    }

    private func checkReadSize(_ text: String) throws {
        guard text.utf8.count <= 120_000 else { throw Failure("内容过长，未授权修改。请减少每批卡片数量；超长原资料请先手动拆分。") }
    }

    private func allCards() throws -> [ConceptCard] {
        try context.fetch(FetchDescriptor<ConceptCard>(sortBy: [SortDescriptor(\.createdAt), SortDescriptor(\.title)]))
    }

    private func allNotes() throws -> [ResearchNote] {
        try context.fetch(FetchDescriptor<ResearchNote>(sortBy: [SortDescriptor(\.createdAt), SortDescriptor(\.title)]))
    }

    private func allLinks() throws -> [ConceptLink] { try context.fetch(FetchDescriptor<ConceptLink>()) }

    private func findCards(_ ids: [UUID]) throws -> [ConceptCard] {
        let cards = try allCards()
        return try ids.map { id in
            guard let card = cards.first(where: { $0.id == id }) else { throw Failure("卡片已不存在，请重新查找。") }
            return card
        }
    }

    private func findNote(_ id: UUID) throws -> ResearchNote {
        guard let note = try allNotes().first(where: { $0.id == id }) else { throw Failure("原资料已不存在，请重新查找。") }
        return note
    }

    private func matches(_ query: String, in fields: [String]) -> Bool {
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        return query.isEmpty || fields.contains { $0.localizedStandardContains(query) }
    }

    private func page(_ items: [JSONValue], key: String, offset: Int, limit: Int) -> JSONValue {
        let page = Array(items.dropFirst(offset).prefix(limit))
        let end = min(offset, items.count) + page.count
        return .object([key: .array(page), "total": .number(Double(items.count)),
                        "next_offset": end < items.count ? .number(Double(end)) : .null])
    }

    private func mergedSources(_ cards: [ConceptCard]) -> [WebSource] {
        var result: [WebSource] = []
        for source in cards.flatMap(\.sources) where !result.contains(where: { $0.url == source.url }) { result.append(source) }
        return result
    }

    private func sourceData(_ sources: [WebSource]) -> JSONValue {
        .array(sources.enumerated().map { index, source in
            ["number": .number(Double(index + 1)), "url": .string(source.url), "title": .string(source.title)]
        })
    }

    private func cardData(_ card: ConceptCard) -> [String: JSONValue] {
        ["id": .string(card.id.uuidString), "title": .string(card.title), "content": .string(card.content),
         "example": .string(card.example), "subject": .string(card.subjectRaw), "topic": .string(card.topic),
         "sources": sourceData(card.sources), "sources_json": .string(card.sourcesJSON),
         "created_at": .string(String(card.createdAt.timeIntervalSince1970.bitPattern)), "updated_at": .string(String(card.updatedAt.timeIntervalSince1970.bitPattern)),
         "group_id": card.noteID.map { .string($0.uuidString) } ?? .null,
         "conversation_id": card.sourceConversationID.map { .string($0.uuidString) } ?? .null,
         "model": .string(card.modelName), "map_x": card.mapX.map { .string(String($0.bitPattern)) } ?? .null,
         "map_y": card.mapY.map { .string(String($0.bitPattern)) } ?? .null]
    }

    private func noteData(_ note: ResearchNote) -> [String: JSONValue] {
        ["id": .string(note.id.uuidString), "title": .string(note.title), "content": .string(note.content),
         "subject": .string(note.subjectRaw), "topic": .string(note.topic), "sources": sourceData(note.sources),
         "sources_json": .string(note.sourcesJSON), "component_state": .string(note.componentStateJSON),
         "created_at": .string(String(note.createdAt.timeIntervalSince1970.bitPattern)), "updated_at": .string(String(note.updatedAt.timeIntervalSince1970.bitPattern)),
         "conversation_id": note.sourceConversationID.map { .string($0.uuidString) } ?? .null,
         "model": .string(note.modelName), "is_card_based": .bool(note.isCardBased)]
    }

    private func digest(_ fields: [String: JSONValue]) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = (try? encoder.encode(JSONValue.object(fields))) ?? Data()
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}
