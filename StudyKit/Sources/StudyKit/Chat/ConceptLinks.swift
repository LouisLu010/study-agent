import Foundation

/// 关联的种类（见 GLOSSARY「关联」）。
public enum LinkKind: String, CaseIterable, Identifiable, Sendable, Codable {
    /// 先懂 A 才能懂 B，从 A 指向 B。
    case prerequisite
    /// 容易混淆的两个概念，没有方向。
    case contrast
    /// B 是 A 的用法，从 A 指向 B。
    case application

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .prerequisite: "前置"
        case .contrast: "对比"
        case .application: "应用"
        }
    }

    public var isDirected: Bool { self != .contrast }

    /// 模型写的种类：英文或中文都认，认不出返回 nil。
    public static func parse(_ text: String) -> LinkKind? {
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if let kind = LinkKind(rawValue: value) { return kind }
        switch value {
        case "前置", "前置知识", "prereq", "requires": return .prerequisite
        case "对比", "比较", "compare", "contrast": return .contrast
        case "应用", "用法", "apply", "use": return .application
        default: return nil
        }
    }

    /// 从卡片 `card` 看过去，这条关联怎么称呼另一头。例如 A 是 B 的前置时，在 B 里 A 显示在"前置"下，在 A 里 B 显示在"后续"下。
    public func label(fromSide isFrom: Bool) -> String {
        switch self {
        case .prerequisite: isFrom ? "后续" : "前置"
        case .contrast: "对比"
        case .application: isFrom ? "应用" : "依据"
        }
    }
}

/// 关系图和排布用的坐标。不用 CGPoint，StudyKit 在 Linux 上也能测。
public struct MapPoint: Sendable, Equatable, Codable {
    public var x: Double
    public var y: Double

    public init(x: Double, y: Double) {
        self.x = x
        self.y = y
    }

    static func + (a: MapPoint, b: MapPoint) -> MapPoint { MapPoint(x: a.x + b.x, y: a.y + b.y) }
    static func - (a: MapPoint, b: MapPoint) -> MapPoint { MapPoint(x: a.x - b.x, y: a.y - b.y) }
    static func * (a: MapPoint, k: Double) -> MapPoint { MapPoint(x: a.x * k, y: a.y * k) }
    var length: Double { (x * x + y * y).squareRoot() }
}

/// 一条关联的两头和种类，不带存储细节。校验、排布、找邻居都用它。
public struct LinkEdge: Sendable, Equatable, Hashable {
    public var from: UUID
    public var to: UUID
    public var kind: LinkKind

    public init(from: UUID, to: UUID, kind: LinkKind) {
        self.from = from
        self.to = to
        self.kind = kind
    }

    /// 同一对卡、同一种类算同一条；对比没有方向，两头对调也算同一条。
    public func sameLink(as other: LinkEdge) -> Bool {
        guard kind == other.kind else { return false }
        if from == other.from && to == other.to { return true }
        return !kind.isDirected && from == other.to && to == other.from
    }
}

public enum LinkRules {
    /// 一张卡最多几条关联。
    public static let maxPerCard = 6

    /// 校验一组新提出的关联：丢掉指向不存在的卡、自己连自己、和已有的或彼此重复的、用户删过的，
    /// 每张卡超过上限时按给出的顺序截掉。返回留下的关联在 `proposed` 里的位置。
    public static func accept(
        _ proposed: [LinkEdge],
        knownCards: Set<UUID>,
        existing: [LinkEdge],
        dismissed: [LinkEdge]
    ) -> [Int] {
        var count: [UUID: Int] = [:]
        for edge in existing {
            count[edge.from, default: 0] += 1
            count[edge.to, default: 0] += 1
        }
        var kept: [LinkEdge] = existing
        var result: [Int] = []
        for (index, edge) in proposed.enumerated() {
            guard edge.from != edge.to,
                  knownCards.contains(edge.from), knownCards.contains(edge.to),
                  !kept.contains(where: { $0.sameLink(as: edge) }),
                  !dismissed.contains(where: { $0.sameLink(as: edge) }),
                  count[edge.from, default: 0] < maxPerCard, count[edge.to, default: 0] < maxPerCard
            else { continue }
            kept.append(edge)
            count[edge.from, default: 0] += 1
            count[edge.to, default: 0] += 1
            result.append(index)
        }
        return result
    }

    /// 从 `start` 出发，沿关联（不管方向）走不超过 `hops` 步能到的卡，包括它自己。
    public static func neighborhood(of start: UUID, hops: Int, edges: [LinkEdge]) -> Set<UUID> {
        var seen: Set<UUID> = [start]
        var frontier: Set<UUID> = [start]
        for _ in 0..<max(0, hops) {
            var next: Set<UUID> = []
            for edge in edges {
                if frontier.contains(edge.from), !seen.contains(edge.to) { next.insert(edge.to) }
                if frontier.contains(edge.to), !seen.contains(edge.from) { next.insert(edge.from) }
            }
            if next.isEmpty { break }
            seen.formUnion(next)
            frontier = next
        }
        return seen
    }
}
