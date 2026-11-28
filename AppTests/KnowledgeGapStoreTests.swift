import Foundation
import StudyKit
import SwiftData
import Testing
@testable import StudyAgent

@MainActor @Suite struct KnowledgeGapStoreTests {
    @Test func snapshotsOnlySameSubjectActivePrerequisitesAndSurvivesSourceDeletion() throws {
        let container = try ModelContainer(for: Schema(StudyAgentSchema.models), configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        let context = ModelContext(container)
        let target = ConceptCard(title: "导数", content: "定义"), a = ConceptCard(title: "极限", content: "趋近"), b = ConceptCard(title: "变化率", content: "比值")
        let foreign = ConceptCard(title: "化学概念", content: "反应")
        for card in [target, a, b, foreign] { context.insert(card); card.subject = .math }
        foreign.subject = .chemistry
        let removed = ConceptLink(from: b.id, to: target.id, kind: .prerequisite); removed.dismissed = true
        for link in [ConceptLink(from: a.id, to: target.id, kind: .prerequisite), removed,
                     ConceptLink(from: foreign.id, to: target.id, kind: .prerequisite)] { context.insert(link) }
        try context.save()
        let prepared = try KnowledgeGapStore.prepare(target: target, context: context, hiddenIDs: [])
        #expect(prepared.materials.map(\.id) == [target.id, a.id])
        #expect(prepared.materials[1].location.contains("导数 ← 极限"))
        let hidden = try KnowledgeGapStore.prepare(target: target, context: context, hiddenIDs: [a.persistentModelID])
        #expect(hidden.materials.count == 1)
        let record = StudyInvestigation(kind: .gaps, title: "检查")
        try record.setMaterials(prepared.materials); context.insert(record)
        context.delete(a); try context.save()
        #expect(try record.materials()[1].content == "趋近")
    }

    @Test func answerChangesInvalidateAssessmentAndPersistWithoutChangingCards() throws {
        let container = try ModelContainer(for: Schema(StudyAgentSchema.models), configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        let context = ModelContext(container)
        let id = UUID(), record = StudyInvestigation(kind: .gaps, title: "检查")
        let raw = "{\"questions\":[{\"conceptID\":\"\(id)\",\"prompt\":\"问题\",\"referenceAnswer\":\"答案\",\"rubric\":\"依据\"}]}"
        let plan = try KnowledgeGap.parsePlan(raw, conceptIDs: [id])
        let node = KnowledgeGap.prerequisites(target: id, known: [id], edges: [])
        record.detailJSON = try StudyToolJSON.encode(KnowledgeGap.Session(nodes: node, plan: plan))
        record.resultJSON = "old"; context.insert(record)
        try KnowledgeGapStore.answer("不知道", conceptID: id, record: record, context: context)
        let stored = try #require(ModelContext(container).fetch(FetchDescriptor<StudyInvestigation>()).first)
        #expect(stored.resultJSON.isEmpty)
        let session = try StudyToolJSON.decode(KnowledgeGap.Session.self, from: stored.detailJSON)
        #expect(session.answers[id.uuidString] == "不知道" && session.plan == plan)
        #expect(throws: StudyToolError.self) { try KnowledgeGapStore.answer("错题", conceptID: UUID(), record: record, context: context) }
    }
}
