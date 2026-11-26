import Foundation
import Testing
@testable import StudyKit

@Suite struct ConceptMapLayoutTests {
    func ids(_ n: Int) -> [UUID] {
        (0..<n).map { UUID(uuidString: String(format: "00000000-0000-0000-0000-%012d", $0 + 1))! }
    }

    @Test func sameInputSameLayout() {
        let id = ids(6)
        let edges = [LinkEdge(from: id[0], to: id[1], kind: .prerequisite), LinkEdge(from: id[1], to: id[2], kind: .application)]
        let a = ConceptMapLayout.layout(id.map { .init(id: $0) }, edges: edges)
        let b = ConceptMapLayout.layout(id.reversed().map { .init(id: $0) }, edges: edges)
        for i in id { #expect(a[i] == b[i]) }
    }

    @Test func pinnedNodesStayPut() {
        let id = ids(4)
        let pin = MapPoint(x: 500, y: -300)
        let result = ConceptMapLayout.layout(
            [.init(id: id[0], pinned: pin)] + id.dropFirst().map { .init(id: $0) },
            edges: [LinkEdge(from: id[0], to: id[1], kind: .contrast)]
        )
        #expect(result[id[0]] == pin)
    }

    @Test func linkedNodesCloserThanUnlinked() {
        let id = ids(8)
        let edges = [LinkEdge(from: id[0], to: id[1], kind: .prerequisite)]
        let p = ConceptMapLayout.layout(id.map { .init(id: $0) }, edges: edges)
        let linked = (p[id[0]]! - p[id[1]]!).length
        let others = id.dropFirst(2).map { (p[id[0]]! - p[$0]!).length }
        #expect(linked < others.reduce(0, +) / Double(others.count))
    }

    @Test func staysCompact() {
        let id = ids(12)
        let p = ConceptMapLayout.layout(id.map { .init(id: $0) }, edges: [])
        let radius = p.values.map(\.length).max()!
        #expect(radius < ConceptMapLayout.spacing * 6)
    }

    @Test func nodesDoNotOverlap() {
        let id = ids(30)
        let edges = (1..<30).map { LinkEdge(from: id[$0 / 2], to: id[$0], kind: .prerequisite) }
        let p = ConceptMapLayout.layout(id.map { .init(id: $0) }, edges: edges)
        var closest = Double.infinity
        for i in 0..<30 { for j in (i + 1)..<30 { closest = min(closest, (p[id[i]]! - p[id[j]]!).length) } }
        #expect(closest > 80)
    }

    @Test func addingACardBarelyMovesTheOthers() {
        let id = ids(10)
        let edges = (1..<9).map { LinkEdge(from: id[$0 - 1], to: id[$0], kind: .prerequisite) }
        let first = ConceptMapLayout.layout(id.prefix(9).map { .init(id: $0) }, edges: edges)
        let second = ConceptMapLayout.layout(
            id.prefix(9).map { .init(id: $0, previous: first[$0]) } + [.init(id: id[9])],
            edges: edges + [LinkEdge(from: id[4], to: id[9], kind: .application)]
        )
        let moved = id.prefix(9).map { (first[$0]! - second[$0]!).length }.max()!
        #expect(moved < ConceptMapLayout.spacing * 0.6)
        // 新卡落在它关联的那张卡附近。
        #expect((second[id[9]]! - second[id[4]]!).length < ConceptMapLayout.spacing * 2)
    }
}
