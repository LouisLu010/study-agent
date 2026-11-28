import Foundation
import StudyKit
import SwiftData
import Testing
@testable import StudyAgent

@MainActor @Suite struct ReadingComparisonStoreTests {
    private func fixture() throws -> (ModelContainer, ModelContext, StudyInvestigation) {
        let container = try ModelContainer(for: Schema(StudyAgentSchema.models), configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        let context = ModelContext(container)
        let sources = [StudyMaterial(title: "教材", content: "导数是瞬时变化率", location: "第 12 页"), StudyMaterial(title: "讲义", content: "导数是瞬时变化率", location: "第一章")]
        let evidence: [JSONValue] = sources.map { ["sourceID": .string($0.id.uuidString), "startLine": 1, "endLine": 1, "quote": "瞬时变化率"] }
        let rows: [JSONValue] = ["definition", "premise", "conclusion"].map { ["aspect": .string($0), "agreement": "agrees", "explanation": "原文一致", "evidence": .array(evidence)] }
        let json: JSONValue = ["comparisons": .array(rows), "synthesis": "确认的理解"]
        let record = StudyInvestigation(kind: .reading, title: "导数")
        record.inputText = "导数"; record.resultJSON = json.jsonString
        try record.setMaterials(sources); context.insert(record); try context.save()
        return (container, context, record)
    }

    @Test func confirmedCardKeepsEvidenceAfterDeletingInvestigation() throws {
        let (container, context, record) = try fixture()
        let card = try ReadingComparisonStore.saveCard(record: record, title: "导数", content: "我确认导数描述瞬时变化率。", subject: .math, context: context)
        #expect(card.content.contains("第 12 页") && card.content.contains("我确认"))
        context.delete(record); try context.save()
        let stored = try #require(ModelContext(container).fetch(FetchDescriptor<ConceptCard>()).first)
        let bundle = try #require(ReadingComparisonStore.bundles(stored).first)
        #expect(bundle.materials.count == 2 && bundle.materials[0].content == "导数是瞬时变化率")
        #expect(bundle.result.comparisons.count == 3)
    }

    @Test func invalidResultOrEmptyConfirmationDoesNotInsertCard() throws {
        let (_, context, record) = try fixture()
        #expect(throws: StudyToolError.self) { try ReadingComparisonStore.saveCard(record: record, title: "", content: "理解", subject: .math, context: context) }
        #expect(throws: StudyToolError.self) { try ReadingComparisonStore.saveCard(record: record, title: "导数", content: "理解", subject: .math, context: context, expectedResult: "旧的结果") }
        record.resultJSON = "bad"
        #expect(throws: StudyToolError.self) { try ReadingComparisonStore.saveCard(record: record, title: "导数", content: "理解", subject: .math, context: context) }
        #expect(try context.fetchCount(FetchDescriptor<ConceptCard>()) == 0)
    }

    @Test func mergingKeepsDistinctEvidenceAndUndoRestoresPayload() throws {
        let (_, context, record) = try fixture()
        let a = try ReadingComparisonStore.saveCard(record: record, title: "A", content: "理解 A", subject: .math, context: context)
        let b = try ReadingComparisonStore.saveCard(record: record, title: "B", content: "理解 B", subject: .math, context: context)
        let mergedData = try ReadingComparisonStore.mergedEvidence([a, b, a])
        let merged = try #require(mergedData)
        #expect(try JSONDecoder().decode([ReadingComparison.SourceBundle].self, from: merged).count == 2)
        let before = try LibraryAssistantSnapshot(context: context)
        a.readingEvidenceData = nil; try context.save()
        let change = LibraryAssistantChange(before: before, after: try LibraryAssistantSnapshot(context: context), summary: "证据变化")
        #expect(change.changedCardIDs == [a.id])
        try change.undo(in: context)
        #expect(try ReadingComparisonStore.bundles(a).count == 1)
        #expect(try ReadingComparisonStore.mergedEvidence([]) == nil)
    }
}
