import Foundation
import Testing
@testable import StudyKit

@Suite struct ConditionExplorationTests {
    @Test func createsIndependentVariantAndPreservesOriginalAndImages() throws {
        let original = StudyMaterial(title: "函数", content: "已知 x > 0，求 x² 的范围。", images: [.init(data: Data([1, 2]))])
        let changed = try ConditionExploration.variant(original: original, change: .init(operation: .replace, fragment: "x > 0", replacement: "x ∈ R"))
        #expect(changed.content == "已知 x ∈ R，求 x² 的范围。")
        #expect(original.content == "已知 x > 0，求 x² 的范围。" && changed.id != original.id)
        #expect(changed.images == original.images && changed.reference == nil)
        let removed = try ConditionExploration.variant(original: original, change: .init(operation: .remove, fragment: "已知 x > 0，"))
        #expect(removed.content == "求 x² 的范围。")
    }

    @Test func rejectsMissingAmbiguousOverlappingOrNoOpChanges() {
        let source = StudyMaterial(title: "题", content: "a=1，a=1，求 a")
        for change in [ConditionExploration.Change(operation: .remove, fragment: "a=1"), .init(operation: .remove, fragment: "不存在"),
                       .init(operation: .replace, fragment: "求 a", replacement: "求 a"), .init(operation: .replace, fragment: "求 a", replacement: " ")] {
            #expect(throws: StudyToolError.self) { try ConditionExploration.variant(original: source, change: change) }
        }
        #expect(throws: StudyToolError.self) { try ConditionExploration.variant(original: .init(title: "", content: "aaa"), change: .init(operation: .remove, fragment: "aa")) }
        #expect(throws: StudyToolError.self) { try ConditionExploration.variant(original: .init(title: "", content: "题"), change: .init(operation: .remove, fragment: "题")) }
    }

    @Test func checksStepQuotesAndCounterexampleVerification() throws {
        let result = ConditionExploration.Result(steps: [.init(originalStep: "除以 x", sourceQuote: "除以 x", status: .changes, reason: "变式允许 x=0", revisedStep: "先分 x=0 与非零情况")],
                                                 counterexample: .init(status: .found, candidate: "x=0", verification: "满足变式条件，不能除以 x"), conclusion: "必须分类讨论")
        #expect(try ConditionExploration.parse(StudyToolJSON.encode(result), solution: "先除以 x") == result)
        #expect(throws: StudyToolError.self) { try ConditionExploration.parse(StudyToolJSON.encode(result), solution: "两边平方") }
        var bad = result; bad.counterexample.verification = ""
        #expect(throws: StudyToolError.self) { try ConditionExploration.parse(StudyToolJSON.encode(bad), solution: "") }
        bad = result; bad.counterexample.candidate = ""
        #expect(throws: StudyToolError.self) { try ConditionExploration.parse(StudyToolJSON.encode(bad), solution: "") }
        bad = result; bad.steps[0].revisedStep = ""
        #expect(throws: StudyToolError.self) { try ConditionExploration.parse(StudyToolJSON.encode(bad), solution: "") }
    }

    @Test func requestContainsExactOriginalVariantAndChange() throws {
        let original = StudyMaterial(title: "函数", content: "已知 x > 0，求值")
        let change = ConditionExploration.Change(operation: .replace, fragment: "x > 0", replacement: "x >= 0")
        let request = try ConditionExploration.request(model: "test", original: original, change: change, solution: "先除以 x")
        let json = try #require(JSONValue.parse(request.messages[0].text))
        #expect(json["original"]?.stringValue == original.content)
        #expect(json["variant"]?.stringValue == "已知 x >= 0，求值")
        #expect(request.tools.isEmpty && !request.webSearch)
        #expect(throws: StudyToolError.tooLong) { try ConditionExploration.request(model: "test", original: original, change: change, solution: String(repeating: "a", count: 20_001)) }
    }
}
