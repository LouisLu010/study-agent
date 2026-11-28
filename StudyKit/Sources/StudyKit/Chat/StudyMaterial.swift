import Foundation

/// 用户选入学习工具的一份原文快照，保留来源位置和图片。
public struct StudyMaterial: Codable, Sendable, Identifiable, Equatable {
    public var id: UUID
    public var title: String
    public var content: String
    public var location: String
    public var reference: StudyReference?
    public var componentStateJSON: String
    public var images: [Image]

    public struct Image: Codable, Sendable, Equatable {
        public var assetID: UUID?
        public var data: Data
        public var contentType: String
        public init(assetID: UUID? = nil, data: Data, contentType: String = "image/jpeg") {
            self.assetID = assetID; self.data = data; self.contentType = contentType
        }
    }

    public init(id: UUID = UUID(), title: String, content: String, location: String = "",
                reference: StudyReference? = nil, componentStateJSON: String = "", images: [Image] = []) {
        self.id = id; self.title = title; self.content = content; self.location = location
        self.reference = reference; self.componentStateJSON = componentStateJSON; self.images = images
    }
}
