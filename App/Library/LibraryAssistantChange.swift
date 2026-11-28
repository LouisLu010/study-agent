import Foundation
import StudyKit
import SwiftData

/// 资料助手操作前后的值快照；保留原始存储字段，避免来源 JSON 或未知枚举值被重新编码。
@MainActor
struct LibraryAssistantSnapshot: Equatable {
    fileprivate struct Card: Equatable, Sendable {
        let id: UUID
        let createdAt: Date
        let updatedAt: Date
        let title: String
        let content: String
        let example: String
        let subjectRaw: String
        let topic: String
        let sourcesJSON: String
        let noteID: UUID?
        let sourceConversationID: UUID?
        let modelName: String
        let mapXBits: UInt64?
        let mapYBits: UInt64?

        init(_ card: ConceptCard) {
            id = card.id
            createdAt = card.createdAt
            updatedAt = card.updatedAt
            title = card.title
            content = card.content
            example = card.example
            subjectRaw = card.subjectRaw
            topic = card.topic
            sourcesJSON = card.sourcesJSON
            noteID = card.noteID
            sourceConversationID = card.sourceConversationID
            modelName = card.modelName
            // 按位记录可保留 -0，也不会让旧数据中的 NaN 与自身比较不相等。
            mapXBits = card.mapX?.bitPattern
            mapYBits = card.mapY?.bitPattern
        }

        func apply(to card: ConceptCard) {
            card.id = id
            card.createdAt = createdAt
            card.updatedAt = updatedAt
            card.title = title
            card.content = content
            card.example = example
            card.subjectRaw = subjectRaw
            card.topic = topic
            card.sourcesJSON = sourcesJSON
            card.noteID = noteID
            card.sourceConversationID = sourceConversationID
            card.modelName = modelName
            card.mapX = mapXBits.map { Double(bitPattern: $0) }
            card.mapY = mapYBits.map { Double(bitPattern: $0) }
        }
    }

    fileprivate struct Note: Equatable, Sendable {
        let id: UUID
        let createdAt: Date
        let updatedAt: Date
        let title: String
        let subjectRaw: String
        let topic: String
        let content: String
        let componentStateJSON: String
        let sourcesJSON: String
        let modelName: String
        let sourceConversationID: UUID?
        let isCardBased: Bool

        init(_ note: ResearchNote) {
            id = note.id
            createdAt = note.createdAt
            updatedAt = note.updatedAt
            title = note.title
            subjectRaw = note.subjectRaw
            topic = note.topic
            content = note.content
            componentStateJSON = note.componentStateJSON
            sourcesJSON = note.sourcesJSON
            modelName = note.modelName
            sourceConversationID = note.sourceConversationID
            isCardBased = note.isCardBased
        }

        func apply(to note: ResearchNote) {
            note.id = id
            note.createdAt = createdAt
            note.updatedAt = updatedAt
            note.title = title
            note.subjectRaw = subjectRaw
            note.topic = topic
            note.content = content
            note.componentStateJSON = componentStateJSON
            note.sourcesJSON = sourcesJSON
            note.modelName = modelName
            note.sourceConversationID = sourceConversationID
            note.isCardBased = isCardBased
        }
    }

    fileprivate struct Link: Equatable, Sendable {
        let id: UUID
        let createdAt: Date
        let fromID: UUID?
        let toID: UUID?
        let kindRaw: String
        let reason: String
        let isManual: Bool
        let dismissed: Bool

        init(_ link: ConceptLink) {
            id = link.id
            createdAt = link.createdAt
            fromID = link.fromID
            toID = link.toID
            kindRaw = link.kindRaw
            reason = link.reason
            isManual = link.isManual
            dismissed = link.dismissed
        }

        func apply(to link: ConceptLink) {
            link.id = id
            link.createdAt = createdAt
            link.fromID = fromID
            link.toID = toID
            link.kindRaw = kindRaw
            link.reason = reason
            link.isManual = isManual
            link.dismissed = dismissed
        }

        var cardIDs: Set<UUID> { Set([fromID, toID].compactMap { $0 }) }
    }

    fileprivate let cards: [UUID: Card]
    fileprivate let notes: [UUID: Note]
    fileprivate let links: [UUID: Link]

    init(context: ModelContext) throws {
        cards = try Self.keyed(context.fetch(FetchDescriptor<ConceptCard>()).map(Card.init), id: \.id)
        notes = try Self.keyed(context.fetch(FetchDescriptor<ResearchNote>()).map(Note.init), id: \.id)
        links = try Self.keyed(context.fetch(FetchDescriptor<ConceptLink>()).map(Link.init), id: \.id)
    }

    private init(cards: [UUID: Card], notes: [UUID: Note], links: [UUID: Link]) {
        self.cards = cards
        self.notes = notes
        self.links = links
    }

    fileprivate func retaining(cards cardIDs: Set<UUID>, notes noteIDs: Set<UUID>, links linkIDs: Set<UUID>) -> Self {
        Self(
            cards: cards.filter { cardIDs.contains($0.key) },
            notes: notes.filter { noteIDs.contains($0.key) },
            links: links.filter { linkIDs.contains($0.key) }
        )
    }

    fileprivate static func keyed<Value>(_ values: [Value], id: KeyPath<Value, UUID>) throws -> [UUID: Value] {
        var result: [UUID: Value] = [:]
        for value in values {
            guard result.updateValue(value, forKey: value[keyPath: id]) == nil else {
                throw LibraryAssistantChange.UndoError.duplicateIdentity
            }
        }
        return result
    }

    fileprivate func links(touching cardIDs: Set<UUID>) -> [UUID: Link] {
        links.filter { !$0.value.cardIDs.isDisjoint(with: cardIDs) }
    }

    fileprivate func members(of noteIDs: Set<UUID>) -> [UUID: UUID] {
        var result: [UUID: UUID] = [:]
        for card in cards.values {
            if let noteID = card.noteID, noteIDs.contains(noteID) { result[card.id] = noteID }
        }
        return result
    }
}

/// 单次工具操作的撤销记录。只恢复差异中的实体，不回放整份资料库。
@MainActor
struct LibraryAssistantChange: Identifiable {
    enum UndoError: LocalizedError, Equatable {
        case changedSinceOperation
        case duplicateIdentity

        var errorDescription: String? {
            switch self {
            case .changedSinceOperation: "这些资料或关联后来已被修改，无法安全撤销。新内容已保留。"
            case .duplicateIdentity: "资料中存在重复的记录 ID，无法安全记录或撤销修改。"
            }
        }
    }

    let id = UUID()
    let summary: String
    let changedCardIDs: Set<UUID>
    let changedNoteIDs: Set<UUID>
    let changedLinkIDs: Set<UUID>
    private let before: LibraryAssistantSnapshot
    private let after: LibraryAssistantSnapshot
    private let expectedLinks: [UUID: LibraryAssistantSnapshot.Link]
    private let expectedMembers: [UUID: UUID]
    private let expectedCardPresence: [UUID: Bool]
    private let expectedNotePresence: [UUID: Bool]

    init(before: LibraryAssistantSnapshot, after: LibraryAssistantSnapshot, summary: String) {
        self.summary = summary
        changedCardIDs = Self.changedIDs(before.cards, after.cards)
        changedNoteIDs = Self.changedIDs(before.notes, after.notes)
        changedLinkIDs = Self.changedIDs(before.links, after.links)
        // 撤销记录只长期保留本次差异和周边校验信息，释放整库快照。
        self.before = before.retaining(cards: changedCardIDs, notes: changedNoteIDs, links: changedLinkIDs)
        self.after = after.retaining(cards: changedCardIDs, notes: changedNoteIDs, links: changedLinkIDs)
        expectedLinks = after.links(touching: changedCardIDs)
        expectedMembers = after.members(of: changedNoteIDs)
        let linkedCardIDs = changedLinkIDs.reduce(into: Set<UUID>()) { ids, id in
            ids.formUnion(before.links[id]?.cardIDs ?? [])
            ids.formUnion(after.links[id]?.cardIDs ?? [])
        }
        let noteIDs = changedCardIDs.reduce(into: Set<UUID>()) { ids, id in
            if let noteID = before.cards[id]?.noteID { ids.insert(noteID) }
            if let noteID = after.cards[id]?.noteID { ids.insert(noteID) }
        }
        expectedCardPresence = Dictionary(uniqueKeysWithValues: linkedCardIDs.map { ($0, after.cards[$0] != nil) })
        expectedNotePresence = Dictionary(uniqueKeysWithValues: noteIDs.map { ($0, after.notes[$0] != nil) })
    }

    var isEmpty: Bool { changedCardIDs.isEmpty && changedNoteIDs.isEmpty && changedLinkIDs.isEmpty }

    func undo(in context: ModelContext) throws {
        try undo(in: context, persist: { try $0.save() })
    }

    /// 保存可注入，便于验证提交失败后不会留下部分恢复结果。
    func undo(in context: ModelContext, persist: (ModelContext) throws -> Void) throws {
        guard !isEmpty else { return }
        let current = try LibraryAssistantSnapshot(context: context)
        try validate(current)
        // 当前上下文可能缓存了旧实体；另一个上下文已保存的修改也必须参与冲突检查。
        let persistedContext = ModelContext(context.container)
        persistedContext.autosaveEnabled = false
        try validate(LibraryAssistantSnapshot(context: persistedContext))
        let cards = try LibraryAssistantSnapshot.keyed(context.fetch(FetchDescriptor<ConceptCard>()), id: \.id)
        let notes = try LibraryAssistantSnapshot.keyed(context.fetch(FetchDescriptor<ResearchNote>()), id: \.id)
        let links = try LibraryAssistantSnapshot.keyed(context.fetch(FetchDescriptor<ConceptLink>()), id: \.id)
        // 先保存其他页面的待保存编辑，后续失败仅回滚本次撤销。
        try persist(context)
        do {
            // 先移除本次新增记录。ID 关联没有级联关系，不调用含额外清理逻辑的 delete helper。
            for id in changedLinkIDs where before.links[id] == nil {
                if let link = links[id] { context.delete(link) }
            }
            for id in changedCardIDs where before.cards[id] == nil {
                if let card = cards[id] { context.delete(card) }
            }
            for id in changedNoteIDs where before.notes[id] == nil {
                if let note = notes[id] { context.delete(note) }
            }
            for id in changedNoteIDs {
                guard let original = before.notes[id] else { continue }
                let note = notes[id] ?? ResearchNote(title: original.title, content: original.content)
                if notes[id] == nil { context.insert(note) }
                original.apply(to: note)
            }
            for id in changedCardIDs {
                guard let original = before.cards[id] else { continue }
                let card = cards[id] ?? ConceptCard(title: original.title, content: original.content)
                if cards[id] == nil { context.insert(card) }
                original.apply(to: card)
            }
            for id in changedLinkIDs {
                guard let original = before.links[id] else { continue }
                let link = links[id] ?? ConceptLink(from: original.fromID ?? id, to: original.toID ?? id, kind: .prerequisite)
                if links[id] == nil { context.insert(link) }
                original.apply(to: link)
            }
            // 一次提交包含新增、更新、删除；任何失败都恢复到撤销前保存的基线。
            try persist(context)
        } catch {
            context.rollback()
            throw error
        }
    }

    private func validate(_ current: LibraryAssistantSnapshot) throws {
        guard changedCardIDs.allSatisfy({ current.cards[$0] == after.cards[$0] }),
              changedNoteIDs.allSatisfy({ current.notes[$0] == after.notes[$0] }),
              changedLinkIDs.allSatisfy({ current.links[$0] == after.links[$0] }),
              current.links(touching: changedCardIDs) == expectedLinks,
              current.members(of: changedNoteIDs) == expectedMembers
        else { throw UndoError.changedSinceOperation }

        // 撤销关联不能指回操作后被删的卡；卡片移回资料时同样检查其分组是否仍存在。
        guard expectedCardPresence.allSatisfy({ (current.cards[$0.key] != nil) == $0.value }),
              expectedNotePresence.allSatisfy({ (current.notes[$0.key] != nil) == $0.value })
        else { throw UndoError.changedSinceOperation }
    }

    private static func changedIDs<Value: Equatable>(_ before: [UUID: Value], _ after: [UUID: Value]) -> Set<UUID> {
        Set(before.keys).union(after.keys).filter { before[$0] != after[$0] }
    }
}
