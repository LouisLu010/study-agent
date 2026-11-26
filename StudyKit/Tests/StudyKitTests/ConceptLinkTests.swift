import Foundation
import Testing
@testable import StudyKit

@Suite struct LinkRulesTests {
    let x = UUID(), y = UUID(), z = UUID()

    @Test func dropsBadAndDuplicateLinks() {
        let proposed = [
            LinkEdge(from: x, to: y, kind: .prerequisite),
            LinkEdge(from: x, to: x, kind: .contrast),
            LinkEdge(from: y, to: x, kind: .contrast),
            LinkEdge(from: x, to: y, kind: .contrast),
            LinkEdge(from: x, to: UUID(), kind: .application),
            LinkEdge(from: y, to: z, kind: .application),
        ]
        let kept = LinkRules.accept(
            proposed, knownCards: [x, y, z],
            existing: [], dismissed: [LinkEdge(from: z, to: y, kind: .application)]
        )
        // 对比没有方向：y→x 和 x→y 算同一条。y→z 的应用不是用户删掉的 z→y，留下。
        #expect(kept == [0, 2, 5])
    }

    @Test func dismissedContrastIsIgnoredEitherWay() {
        let kept = LinkRules.accept(
            [LinkEdge(from: x, to: y, kind: .contrast)], knownCards: [x, y],
            existing: [], dismissed: [LinkEdge(from: y, to: x, kind: .contrast)]
        )
        #expect(kept.isEmpty)
    }

    @Test func atMostSixPerCard() {
        let others = (0..<8).map { _ in UUID() }
        let proposed = others.map { LinkEdge(from: x, to: $0, kind: .application) }
        let kept = LinkRules.accept(proposed, knownCards: Set(others + [x]), existing: [], dismissed: [])
        #expect(kept == Array(0..<6))
    }

    @Test func neighborhoodWithinTwoHops() {
        let w = UUID(), far = UUID()
        let edges = [
            LinkEdge(from: x, to: y, kind: .prerequisite),
            LinkEdge(from: z, to: y, kind: .contrast),
            LinkEdge(from: z, to: w, kind: .application),
            LinkEdge(from: w, to: far, kind: .application),
        ]
        #expect(LinkRules.neighborhood(of: x, hops: 2, edges: edges) == [x, y, z])
        #expect(LinkRules.neighborhood(of: x, hops: 0, edges: edges) == [x])
    }

    @Test func kindLabelsFromEachSide() {
        #expect(LinkKind.prerequisite.label(fromSide: false) == "前置")
        #expect(LinkKind.prerequisite.label(fromSide: true) == "后续")
        #expect(LinkKind.parse("前置") == .prerequisite)
        #expect(LinkKind.parse("Contrast") == .contrast)
        #expect(LinkKind.parse("相关") == nil)
    }
}
