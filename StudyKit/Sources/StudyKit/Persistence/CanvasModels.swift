import Foundation
import SwiftData

/// 专题画布。内容保存副本，来源只用于回到原记录。
@Model
public final class StudyCanvas {
    public var id: UUID = UUID()
    public var title: String = "学习画布"
    public var createdAt: Date = Date()
    public var updatedAt: Date = Date()
    public var zoom: Double = 1
    public var offsetX: Double = 0
    public var offsetY: Double = 0

    @Relationship(deleteRule: .cascade, inverse: \CanvasItem.canvas)
    public var items: [CanvasItem]? = []

    public init(title: String) { self.title = title }

    public var sortedItems: [CanvasItem] {
        (items ?? []).filter { !$0.isDeleted }.sorted {
            $0.createdAt == $1.createdAt ? $0.id.uuidString < $1.id.uuidString : $0.createdAt < $1.createdAt
        }
    }
}

@Model
public final class CanvasItem {
    public var id: UUID = UUID()
    public var title: String = ""
    public var content: String = ""
    public var createdAt: Date = Date()
    public var x: Double = 0
    public var y: Double = 0
    public var componentStateJSON: String = ""
    public var sourceKindRaw: String = ""
    public var sourceRecordID: UUID?
    public var sourceLocation: String = ""
    @Attribute(.externalStorage) public var drawingData: Data?
    public var canvas: StudyCanvas?

    @Relationship(deleteRule: .cascade, inverse: \StoredImage.canvasItem)
    public var images: [StoredImage]? = []

    public init(title: String, content: String, x: Double = 0, y: Double = 0) {
        self.title = title
        self.content = content
        self.x = x
        self.y = y
    }

    public var sourceReference: StudyReference? {
        guard let kind = StudyRecordKind(rawValue: sourceKindRaw), let id = sourceRecordID else { return nil }
        return StudyReference(number: 1, kind: kind, recordID: id, title: title)
    }
}
