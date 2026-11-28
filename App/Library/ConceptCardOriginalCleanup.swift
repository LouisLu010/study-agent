import Foundation
import StudyKit
import SwiftData

extension ConceptCardStore {
    enum OriginalCleanupError: LocalizedError {
        case noCards
        case missingOriginal
        case missingImages

        var errorDescription: String? {
            switch self {
            case .noCards: "没有可保存的知识卡，原资料已保留。"
            case .missingOriginal: "原资料已被删除，请关闭预览后重新整理。"
            case .missingImages: "知识卡引用的图片尚未完整保存，原资料已保留。"
            }
        }
    }

    /// 进入资料页时迁移旧版拆卡结果；没有卡片的原资料不删除。
    @discardableResult
    static func removeCardBasedOriginals(
        context: ModelContext, persist: (ModelContext) throws -> Void = { try $0.save() }
    ) throws -> Int {
        try Task.checkCancellation()
        let cards = try context.fetch(FetchDescriptor<ConceptCard>())
        let notes = try context.fetch(FetchDescriptor<ResearchNote>(predicate: #Predicate { $0.isCardBased }))
        let originals = notes.compactMap { note -> (ResearchNote, [ConceptCard])? in
            let ownCards = cards.filter { $0.noteID == note.id }
            return ownCards.isEmpty ? nil : (note, ownCards)
        }
        guard !originals.isEmpty else { return 0 }
        try removeOriginals(originals, context: context, persist: persist)
        return originals.count
    }

    static func removeOriginals(
        _ originals: [(ResearchNote, [ConceptCard])], context: ModelContext,
        persist: (ModelContext) throws -> Void
    ) throws {
        try Task.checkCancellation()
        // 确认卡片已落库，随后元数据迁移与原资料删除一起提交。
        try persist(context)
        do {
            for (note, cards) in originals {
                preserveOriginalReferences(note, in: cards)
                try validateImages(in: cards, context: context)
                context.delete(note)
            }
            try Task.checkCancellation()
            try persist(context)
        } catch {
            context.rollback()
            throw error
        }
    }

    static func preserveOriginalReferences(_ note: ResearchNote, in cards: [ConceptCard]) {
        for card in cards {
            // 已有卡片角标仍指向原来的下标；补充来源只追加，绝不重新排序或编号。
            var sources = card.sources
            for source in note.sources where !sources.contains(where: { $0.url == source.url }) {
                sources.append(source)
            }
            card.sources = sources
            if card.sourceConversationID == nil { card.sourceConversationID = note.sourceConversationID }
        }
    }

    static func validateImages(in cards: [ConceptCard], context: ModelContext) throws {
        let required = Set(cards.flatMap { CompilationCenter.imageIDs(in: $0.content + "\n" + $0.example) })
        guard !required.isEmpty else { return }
        let available = Set(try context.fetch(FetchDescriptor<StoredImage>()).filter { $0.data?.isEmpty == false }.map(\.id))
        guard required.isSubset(of: available) else { throw OriginalCleanupError.missingImages }
        // ResearchNote 没有 StoredImage 关系；删除原资料不会级联删除这些图片。
        // componentStateJSON 仅属于原资料的交互组件，知识卡正文与图片不引用其中的状态。
    }
}
