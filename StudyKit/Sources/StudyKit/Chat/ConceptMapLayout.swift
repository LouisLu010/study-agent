import Foundation

/// 关系图的排布（第十版）：力导向排布，种子固定，同一组卡每次排出来都一样。
/// 用户拖过的节点（`pinned`）不动；新加的卡从和它有关联的卡旁边开始，所以已有的节点大体不挪。
/// 坐标单位就是关系图在缩放为 1 时的点（pt），原点在图的中心附近。
public enum ConceptMapLayout {
    public struct Node: Sendable, Equatable {
        public var id: UUID
        /// 用户拖过的位置；有的话这个节点不动。
        public var pinned: MapPoint?
        /// 上一次排出来的位置（例如这次只是加了几张新卡），有的话从这里开始，没有时从种子决定的位置开始。
        public var previous: MapPoint?

        public init(id: UUID, pinned: MapPoint? = nil, previous: MapPoint? = nil) {
            self.id = id
            self.pinned = pinned
            self.previous = previous
        }
    }

    /// 两个节点中心之间理想的距离。节点上写标题，大约 140×44。
    public static let spacing: Double = 190

    /// 上一次排过的节点这次最多挪多远。
    static let maxDrift = spacing * 0.3

    public static func layout(_ input: [Node], edges: [LinkEdge], iterations: Int = 300) -> [UUID: MapPoint] {
        guard !input.isEmpty else { return [:] }
        // 先按 ID 排好，浮点数的累加顺序固定，节点在数组里的顺序不影响结果。
        var seen = Set<UUID>()
        let nodes = input.filter { seen.insert($0.id).inserted }.sorted { $0.id.uuidString < $1.id.uuidString }
        let ids = nodes.map(\.id)
        let index = Dictionary(uniqueKeysWithValues: ids.enumerated().map { ($1, $0) })
        let pairs = edges.compactMap { edge -> (Int, Int)? in
            guard let a = index[edge.from], let b = index[edge.to], a != b else { return nil }
            return (a, b)
        }
        var neighbors = Array(repeating: [Int](), count: nodes.count)
        for (a, b) in pairs {
            neighbors[a].append(b)
            neighbors[b].append(a)
        }

        // 起始位置：拖过的、上次的位置优先；其余的放在已有位置的邻居旁边，再没有就放在种子决定的螺旋上。
        var position = Array(repeating: MapPoint(x: 0, y: 0), count: nodes.count)
        var placed = Array(repeating: false, count: nodes.count)
        for (i, node) in nodes.enumerated() {
            if let p = node.pinned ?? node.previous {
                position[i] = p
                placed[i] = true
            }
        }
        var spiral = 0
        for i in 0..<nodes.count where !placed[i] {
            let anchors = neighbors[i].filter { placed[$0] }
            let jitter = seededPoint(ids[i], radius: spacing * 0.6)
            if !anchors.isEmpty {
                let center = anchors.reduce(MapPoint(x: 0, y: 0)) { $0 + position[$1] } * (1 / Double(anchors.count))
                position[i] = center + jitter
            } else {
                // 黄金角螺旋，越往后越远，互相不重叠。
                let angle = Double(spiral) * 2.399963
                let radius = spacing * 0.8 * Double(spiral).squareRoot()
                position[i] = MapPoint(x: cos(angle) * radius, y: sin(angle) * radius) + jitter * 0.2
                spiral += 1
            }
            placed[i] = true
        }

        let movable = nodes.map { $0.pinned == nil }
        // 已经有位置的节点（上次排过的）只微调，最多挪 maxDrift；新节点自由移动。
        let freedom = nodes.map { $0.pinned != nil ? 0.0 : ($0.previous != nil ? 0.3 : 1.0) }
        let k = spacing
        var temperature = spacing * 0.5
        let cooling = pow(0.02, 1 / Double(max(iterations, 1)))
        for _ in 0..<iterations {
            var force = Array(repeating: MapPoint(x: 0, y: 0), count: nodes.count)
            for a in 0..<nodes.count {
                for b in (a + 1)..<nodes.count {
                    var delta = position[a] - position[b]
                    var distance = delta.length
                    if distance < 0.01 {
                        delta = seededPoint(ids[a], radius: 1) - seededPoint(ids[b], radius: 1)
                        distance = max(delta.length, 0.01)
                    }
                    let repulse = k * k / distance
                    let push = delta * (repulse / distance)
                    force[a] = force[a] + push
                    force[b] = force[b] - push
                }
            }
            for (a, b) in pairs {
                let delta = position[a] - position[b]
                let distance = max(delta.length, 0.01)
                let pull = delta * ((distance * distance / k) / distance)
                force[a] = force[a] - pull
                force[b] = force[b] + pull
            }
            // 拉向中心，不连通的几团不会越飘越远。
            for i in 0..<nodes.count {
                force[i] = force[i] - position[i] * gravity
            }
            for i in 0..<nodes.count where movable[i] {
                let length = force[i].length
                guard length > 0 else { continue }
                let step = min(length, temperature) * freedom[i]
                position[i] = position[i] + force[i] * (step / length)
                if let start = nodes[i].previous {
                    let drift = position[i] - start
                    if drift.length > maxDrift { position[i] = start + drift * (maxDrift / drift.length) }
                }
            }
            temperature *= cooling
        }
        return Dictionary(uniqueKeysWithValues: zip(ids, position))
    }

    /// 向中心的拉力系数。和排斥力平衡时，n 个节点大约散在半径 √n × spacing 的圆里。
    static let gravity = 1.0

    /// 由 ID 决定的一个偏移，同一个 ID 每次都一样。
    static func seededPoint(_ id: UUID, radius: Double) -> MapPoint {
        var state: UInt64 = 1469598103934665603
        for byte in withUnsafeBytes(of: id.uuid, Array.init) {
            state = (state ^ UInt64(byte)) &* 1099511628211
        }
        let a = Double(state & 0xFFFF) / 65535
        let b = Double((state >> 16) & 0xFFFF) / 65535
        let angle = a * 2 * .pi
        return MapPoint(x: cos(angle) * radius * (0.5 + b / 2), y: sin(angle) * radius * (0.5 + b / 2))
    }
}
