import Foundation
import Testing
@testable import StudyKit

@Suite struct ReadingComparisonTests {
    private let materials = [StudyMaterial(title: "教材", content: "导数\n瞬时变化率\n需要极限存在", location: "第 12 页"),
                             StudyMaterial(title: "讲义", content: "瞬时变化率\n需要极限存在", location: "第一章")]

    private func result() -> ReadingComparison.Result {
        .init(comparisons: ReadingComparison.Aspect.allCases.map { aspect in
            .init(aspect: aspect, agreement: .agrees, explanation: "两份材料一致", evidence: materials.enumerated().map { index, material in
                .init(sourceID: material.id, startLine: index == 0 ? 2 : 1, endLine: index == 0 ? 2 : 1, quote: "瞬时变化率")
            })
        }, synthesis: "导数描述瞬时变化率，需要极限存在。")
    }

    @Test func checksLineRangesAndExactQuotesIncludingUnicode() throws {
        let result = result()
        #expect(try ReadingComparison.parse(StudyToolJSON.encode(result), materials: materials) == result)
        let text = ReadingComparison.sourceText(result, materials: materials)
        #expect(text.contains("第 12 页") && text.components(separatedBy: "教材").count == 2)
        var bad = result; bad.comparisons[0].evidence[0].startLine = 1; bad.comparisons[0].evidence[0].endLine = 1
        #expect(throws: StudyToolError.self) { try ReadingComparison.parse(StudyToolJSON.encode(bad), materials: materials) }
        bad = result; bad.comparisons[0].evidence[0].quote = "平均变化率"
        #expect(throws: StudyToolError.self) { try ReadingComparison.parse(StudyToolJSON.encode(bad), materials: materials) }
        bad = result; bad.comparisons[0].evidence[0].startLine = 0
        #expect(throws: StudyToolError.self) { try ReadingComparison.parse(StudyToolJSON.encode(bad), materials: materials) }
    }

    @Test func requiresSourcesForConclusionsAndRejectsUnknownIDsOrDuplicateAspects() throws {
        var bad = result(); bad.comparisons[0].evidence.removeLast()
        #expect(throws: StudyToolError.self) { try ReadingComparison.parse(StudyToolJSON.encode(bad), materials: materials) }
        bad.comparisons[0].agreement = .insufficient
        #expect(try ReadingComparison.parse(StudyToolJSON.encode(bad), materials: materials).comparisons[0].agreement == .insufficient)
        bad = result(); bad.comparisons[0].evidence[0].sourceID = UUID()
        #expect(throws: StudyToolError.self) { try ReadingComparison.parse(StudyToolJSON.encode(bad), materials: materials) }
        bad = result(); bad.comparisons[1].aspect = .definition
        #expect(throws: StudyToolError.self) { try ReadingComparison.parse(StudyToolJSON.encode(bad), materials: materials) }
    }

    @Test func numbersOriginalLinesAndBoundsRequests() throws {
        let request = try ReadingComparison.request(model: "test", concept: "导数", materials: materials, reasoning: .medium)
        let input = try #require(JSONValue.parse(request.messages[0].text))
        #expect(input["sources"]?.arrayValue?.first?["numberedText"]?.stringValue == "1: 导数\n2: 瞬时变化率\n3: 需要极限存在")
        #expect(request.messages[0].images.isEmpty && !request.webSearch && request.reasoningEffort == .medium)
        #expect(throws: StudyToolError.self) { try ReadingComparison.request(model: "test", concept: " ", materials: materials) }
        #expect(throws: StudyToolError.self) { try ReadingComparison.request(model: "test", concept: "导数", materials: [materials[0]]) }
        #expect(throws: StudyToolError.self) { try ReadingComparison.request(model: "test", concept: "导数", materials: [materials[0], materials[0]]) }
        var large = materials; large[0].content = String(repeating: "字", count: 30_001)
        #expect(throws: StudyToolError.self) { try ReadingComparison.request(model: "test", concept: "导数", materials: large) }
    }
}
