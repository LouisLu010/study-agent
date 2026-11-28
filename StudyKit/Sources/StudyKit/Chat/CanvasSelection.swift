import Foundation

/// 画布坐标和框选规则，和屏幕大小、SwiftUI 手势无关。
public enum CanvasSelection {
    public static let width: Double = 300
    public static let height: Double = 260

    public struct Item: Sendable {
        public var id: UUID
        public var center: MapPoint
        public init(id: UUID, center: MapPoint) { self.id = id; self.center = center }
    }

    public static func clampedZoom(_ value: Double) -> Double {
        value.isFinite ? min(2, max(0.3, value)) : 1
    }

    public static func world(_ point: MapPoint, offset: MapPoint, zoom: Double) -> MapPoint {
        (point - offset) * (1 / clampedZoom(zoom))
    }

    /// 两个方向拖动都支持；与框相交的卡片都被选中。
    public static func selected(items: [Item], from start: MapPoint, to end: MapPoint) -> Set<UUID> {
        guard [start.x, start.y, end.x, end.y].allSatisfy(\.isFinite) else { return [] }
        let left = min(start.x, end.x), right = max(start.x, end.x)
        let top = min(start.y, end.y), bottom = max(start.y, end.y)
        return Set(items.filter {
            $0.center.x + width / 2 >= left && $0.center.x - width / 2 <= right &&
            $0.center.y + height / 2 >= top && $0.center.y - height / 2 <= bottom
        }.map(\.id))
    }

    public struct Material: Sendable {
        public var title: String
        public var content: String
        public var location: String
        public init(title: String, content: String, location: String = "") {
            self.title = title; self.content = content; self.location = location
        }
    }

    public enum InputError: String, LocalizedError {
        case emptySelection = "请先选择要提问的内容。"
        case emptyQuestion = "请填写问题。"
        case tooLarge = "选中的内容超过 40,000 字，请减少选择后再提问。"
        public var errorDescription: String? { rawValue }
    }

    public static func prompt(question: String, materials: [Material]) throws -> String {
        guard !materials.isEmpty else { throw InputError.emptySelection }
        let question = question.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !question.isEmpty else { throw InputError.emptyQuestion }
        let body = materials.enumerated().map { index, value in
            "[画布材料\(index + 1)] \(value.title)\n位置：\(value.location)\n\(value.content)"
        }.joined(separator: "\n\n")
        guard body.count + question.count <= 40_000 else { throw InputError.tooLarge }
        return "以下是我选中的画布材料副本。请区分材料内容与我的问题，按材料编号说明依据。\n\n\(body)\n\n我的问题：\n\(question)"
    }
}
