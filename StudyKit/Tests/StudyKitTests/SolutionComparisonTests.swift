import Foundation
import Testing
@testable import StudyKit

@Suite struct SolutionComparisonTests {
    private func result(own: Bool = false) -> SolutionComparison.Result {
        .init(methods: [.init(title: "因式分解", origin: "generated"), .init(title: "求根公式", origin: own ? "user" : "generated")],
              rows: [.init(goal: "求根", cells: [.init(text: "$(x-1)(x-2)=0$", conditions: ["实数范围"], keyIdea: "积为零", detour: "", originalQuote: ""),
                                                     .init(text: "代入公式", conditions: [], keyIdea: "", detour: "", originalQuote: own ? "求根公式" : "")])],
              conclusion: "两种方法得到相同结果。")
    }

    @Test func acceptsAlignedResultsAndVerifiesUserQuotes() throws {
        let expected = result(own: true)
        #expect(try SolutionComparison.parse(StudyToolJSON.encode(expected), ownSolution: "我使用求根公式") == expected)
        #expect(try SolutionComparison.parse("```json\n" + StudyToolJSON.encode(result()) + "\n```", ownSolution: "") == result())
    }

    @Test func rejectsInventedQuotesMissingColumnsAndEmptySteps() throws {
        #expect(throws: StudyToolError.self) { try SolutionComparison.parse(StudyToolJSON.encode(result(own: true)), ownSolution: "我采用配方") }
        #expect(throws: StudyToolError.self) { try SolutionComparison.parse(StudyToolJSON.encode(result()), ownSolution: "我使用求根公式") }
        var value = result(); value.rows[0].cells.removeLast()
        #expect(throws: StudyToolError.self) { try SolutionComparison.parse(StudyToolJSON.encode(value), ownSolution: "") }
        value = result(); value.rows[0].cells[1] = nil
        #expect(throws: StudyToolError.self) { try SolutionComparison.parse(StudyToolJSON.encode(value), ownSolution: "") }
        value = result(); value.methods[1].title = value.methods[0].title
        #expect(throws: StudyToolError.self) { try SolutionComparison.parse(StudyToolJSON.encode(value), ownSolution: "") }
        value = result(); value.rows[0].cells[0]?.text = " "
        #expect(throws: StudyToolError.self) { try SolutionComparison.parse(StudyToolJSON.encode(value), ownSolution: "") }
    }

    @Test func boundsInputOutputAndKeepsMaterialSeparate() throws {
        let request = try SolutionComparison.request(model: "test", question: .init(title: "题", content: "求解方程"), ownSolution: "我的步骤", reasoning: .high)
        #expect(request.tools.isEmpty && !request.webSearch && request.reasoningEffort == .high)
        #expect(JSONValue.parse(request.messages[0].text)?["question"]?.stringValue == "求解方程")
        #expect(throws: StudyToolError.self) { try SolutionComparison.request(model: "test", question: .init(title: "", content: " "), ownSolution: "") }
        #expect(throws: StudyToolError.self) { try SolutionComparison.request(model: "test", question: .init(title: "", content: "题"), ownSolution: String(repeating: "a", count: 20_001)) }
        #expect(throws: StudyToolError.self) { try StudyToolJSON.decode(SolutionComparison.Result.self, from: "```json\n{}") }
        #expect(throws: StudyToolError.self) { try StudyToolJSON.decode(SolutionComparison.Result.self, from: "不是 JSON") }
        #expect(throws: StudyToolError.tooLong) { try StudyToolJSON.decode(SolutionComparison.Result.self, from: String(repeating: "字", count: 90_000)) }
    }
}
