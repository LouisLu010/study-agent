import Foundation
import StudyKit
import SwiftData

@MainActor
enum KnowledgeGapStore {
    static func prepare(target: ConceptCard, context: ModelContext, hiddenIDs: Set<PersistentIdentifier>) throws -> (materials: [StudyMaterial], session: KnowledgeGap.Session) {
        let cards = try context.fetch(FetchDescriptor<ConceptCard>()).filter {
            !$0.isDeleted && !hiddenIDs.contains($0.persistentModelID) && $0.subjectRaw == target.subjectRaw
        }
        let links = try context.fetch(FetchDescriptor<ConceptLink>()).filter { !$0.dismissed && !$0.isDeleted }
        let nodes = KnowledgeGap.prerequisites(target: target.id, known: Set(cards.map(\.id)), edges: links.compactMap(ConceptCardStore.edge))
        guard !nodes.isEmpty else { throw StudyToolError.invalidInput("目标知识卡已不可用。") }
        let materials = nodes.compactMap { node -> StudyMaterial? in
            guard let card = cards.first(where: { $0.id == node.id }) else { return nil }
            var material = StudyMaterialStore.record(.card(card), context: context)
            material.id = card.id
            material.location = "前置路径：" + node.path.compactMap { id in cards.first { $0.id == id }?.title }.joined(separator: " ← ")
            return material
        }
        return (materials, .init(nodes: nodes))
    }

    static func answer(_ text: String, conceptID: UUID, record: StudyInvestigation, context: ModelContext) throws {
        var session = try StudyToolJSON.decode(KnowledgeGap.Session.self, from: record.detailJSON)
        guard session.plan?.questions.contains(where: { $0.conceptID == conceptID }) == true else {
            throw StudyToolError.invalidInput("这道检查题已不可用。")
        }
        session.answers[conceptID.uuidString] = text
        record.detailJSON = try StudyToolJSON.encode(session)
        // 改答以后旧的分析已不再对应当前证据，须重新分析。
        record.resultJSON = ""; record.errorText = nil; record.statusRaw = "draft"; record.updatedAt = .now
        try context.save()
    }
}
