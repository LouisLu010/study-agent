import Foundation
import Testing
@testable import StudyKit

@Suite struct KnowledgeGapTests {
    @Test func walksPrerequisitesBackwardsWithoutCyclesOrUnrelatedEdges() {
        let target = UUID(), a = UUID(), b = UUID(), after = UUID(), other = UUID()
        let edges = [LinkEdge(from: a, to: target, kind: .prerequisite), .init(from: b, to: a, kind: .prerequisite),
                     .init(from: target, to: b, kind: .prerequisite), .init(from: target, to: after, kind: .prerequisite),
                     .init(from: other, to: target, kind: .contrast)]
        let nodes = KnowledgeGap.prerequisites(target: target, known: [target, a, b, after, other], edges: edges)
        #expect(nodes.map(\.id) == [target, a, b])
        #expect(nodes.last?.path == [target, a, b])
        #expect(KnowledgeGap.prerequisites(target: target, known: [], edges: edges).isEmpty)
    }

    @Test func boundsBreadthAndDepthDeterministically() {
        let ids = (0..<10).map { _ in UUID() }
        let chain = (1..<10).map { LinkEdge(from: ids[$0], to: ids[$0 - 1], kind: .prerequisite) }
        #expect(KnowledgeGap.prerequisites(target: ids[0], known: Set(ids), edges: chain).count == 4)
        let star = ids.dropFirst().map { LinkEdge(from: $0, to: ids[0], kind: .prerequisite) }
        let a = KnowledgeGap.prerequisites(target: ids[0], known: Set(ids), edges: star)
        #expect(a.count == 5)
        #expect(a == KnowledgeGap.prerequisites(target: ids[0], known: Set(ids), edges: star.reversed()))
    }

    @Test func planMustCoverEachRealConceptExactlyOnce() throws {
        let id = UUID()
        let plan = KnowledgeGap.Plan(questions: [.init(conceptID: id, prompt: "导数的含义？", referenceAnswer: "瞬时变化率", rubric: "指出极限")])
        #expect(try KnowledgeGap.parsePlan(StudyToolJSON.encode(plan), conceptIDs: [id]) == plan)
        #expect(throws: StudyToolError.self) { try KnowledgeGap.parsePlan(StudyToolJSON.encode(plan), conceptIDs: [UUID()]) }
        let duplicates = KnowledgeGap.Plan(questions: plan.questions + plan.questions)
        #expect(throws: StudyToolError.self) { try KnowledgeGap.parsePlan(StudyToolJSON.encode(duplicates), conceptIDs: [id]) }
        #expect(throws: StudyToolError.self) { try KnowledgeGap.planRequest(model: "test", materials: [], nodes: []) }
        let request = try KnowledgeGap.planRequest(model: "test", materials: [.init(id: id, title: "导数", content: "瞬时变化率")], nodes: [.init(id: id, path: [id])])
        #expect(!request.webSearch && request.messages[0].text.contains(id.uuidString))
    }

    @Test func assessmentRequiresEvidenceFromCorrespondingAnswerAndTreatsBlanksAsUnknown() throws {
        let a = UUID(), b = UUID()
        var session = KnowledgeGap.Session(nodes: [.init(id: a, path: [a]), .init(id: b, path: [a, b])])
        session.plan = .init(questions: [a, b].map { .init(conceptID: $0, prompt: "问题", referenceAnswer: "答案", rubric: "依据") })
        #expect(throws: StudyToolError.self) { try KnowledgeGap.assessmentRequest(model: "test", session: session) }
        session.answers[a.uuidString] = "我认为是平均变化率"
        let good = KnowledgeGap.Assessment(findings: [.init(conceptID: a, verdict: .review, evidenceQuote: "平均变化率", reason: "未取极限", nextStep: "复习极限定义"),
                                                      .init(conceptID: b, verdict: .insufficient, evidenceQuote: "", reason: "未作答", nextStep: "先回答此题")])
        #expect(try KnowledgeGap.parseAssessment(StudyToolJSON.encode(good), session: session) == good)
        #expect(try KnowledgeGap.assessmentRequest(model: "test", session: session).messages[0].text.contains("平均变化率"))
        var bad = good; bad.findings[0].evidenceQuote = "瞬时变化率"
        #expect(throws: StudyToolError.self) { try KnowledgeGap.parseAssessment(StudyToolJSON.encode(bad), session: session) }
        bad = good; bad.findings[1].verdict = .review
        #expect(throws: StudyToolError.self) { try KnowledgeGap.parseAssessment(StudyToolJSON.encode(bad), session: session) }
        bad = good; bad.findings[1].conceptID = UUID()
        #expect(throws: StudyToolError.self) { try KnowledgeGap.parseAssessment(StudyToolJSON.encode(bad), session: session) }
    }
}
