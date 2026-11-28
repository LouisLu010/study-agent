import Foundation
import SwiftData

public enum InvestigationKind: String, Codable, CaseIterable, Identifiable, Sendable {
    case comparison
    case gaps
    case conditions
    public var id: String { rawValue }
    public var title: String {
        switch self {
        case .comparison: "多解对照"
        case .gaps: "知识缺口定位"
        case .conditions: "条件探索"
        }
    }
    public var symbol: String {
        switch self {
        case .comparison: "rectangle.split.2x1"
        case .gaps: "point.3.connected.trianglepath.dotted"
        case .conditions: "arrow.triangle.branch"
        }
    }
}

/// 一次专题分析。输入和结果分开保存，失败与取消不修改原材料。
@Model
public final class StudyInvestigation {
    public var id: UUID = UUID()
    public var kindRaw: String = "comparison"
    public var title: String = ""
    public var createdAt: Date = Date()
    public var updatedAt: Date = Date()
    @Attribute(.externalStorage) public var materialsData: Data?
    public var inputText: String = ""
    public var detailJSON: String = ""
    public var resultJSON: String = ""
    public var statusRaw: String = "draft"
    public var errorText: String?
    public var modelName: String = ""
    public var modelID: UUID?
    public var inputTokens: Int = 0
    public var outputTokens: Int = 0
    public var costCNY: Double?

    public init(kind: InvestigationKind, title: String) { kindRaw = kind.rawValue; self.title = title }

    public var kind: InvestigationKind? { InvestigationKind(rawValue: kindRaw) }

    public func materials() throws -> [StudyMaterial] {
        guard let materialsData else { return [] }
        return try JSONDecoder().decode([StudyMaterial].self, from: materialsData)
    }

    public func setMaterials(_ values: [StudyMaterial]) throws { materialsData = try JSONEncoder().encode(values) }
}
