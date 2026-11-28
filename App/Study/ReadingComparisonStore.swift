import Foundation
import StudyKit
import SwiftData

@MainActor
enum ReadingComparisonStore {
    @discardableResult
    static func saveCard(record: StudyInvestigation, title: String, content: String, subject: Subject, context: ModelContext, expectedResult: String? = nil) throws -> ConceptCard {
        if let expectedResult, expectedResult != record.resultJSON {
            throw StudyToolError.invalidInput("对照结果已更新，请关闭后重新核对再保存。")
        }
        guard record.kind == .reading, StudyToolJSON.nonempty(title, max: 100), StudyToolJSON.nonempty(content, max: 20_000) else {
            throw StudyToolError.invalidInput("请填写知识卡标题和确认后的内容。")
        }
        let materials = try record.materials()
        let result = try ReadingComparison.parse(record.resultJSON, materials: materials)
        let evidence = ReadingComparison.sourceText(result, materials: materials)
        guard !evidence.isEmpty else { throw StudyToolError.invalidInput("目前没有可核对的原文证据，请补充材料后再保存知识卡。") }
        let card = ConceptCard(title: title, content: content + "\n\n已核对的原文：\n\n" + evidence)
        card.subject = subject; card.topic = record.inputText; card.modelName = record.modelName
        // 同一探索重新分析后可产生不同结论，每次确认的证据都必须独立保留。
        card.readingEvidenceData = try JSONEncoder().encode([ReadingComparison.SourceBundle(id: UUID(), materials: materials, result: result)])
        context.insert(card)
        do { try context.save() } catch { context.delete(card); throw error }
        return card
    }

    static func bundles(_ card: ConceptCard) throws -> [ReadingComparison.SourceBundle] {
        guard let data = card.readingEvidenceData else { return [] }
        return try JSONDecoder().decode([ReadingComparison.SourceBundle].self, from: data)
    }

    static func mergedEvidence(_ cards: [ConceptCard]) throws -> Data? {
        var seen: Set<UUID> = []
        let bundles = try cards.flatMap(bundles).filter { seen.insert($0.id).inserted }
        return bundles.isEmpty ? nil : try JSONEncoder().encode(bundles)
    }
}
