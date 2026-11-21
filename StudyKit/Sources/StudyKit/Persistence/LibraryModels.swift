import Foundation
import SwiftData

// 资料和汇编。和其他模型一样遵守 CloudKit 的约束（见 docs/adr/0004），保存独立副本（见 docs/adr/0009）。

/// 资料：模型把会话里的内容和出处整理成的一份总结。
@Model
public final class ResearchNote {
    public var id: UUID = UUID()
    public var createdAt: Date = Date()
    public var updatedAt: Date = Date()
    public var title: String = ""
    /// 科目，`Subject` 的原始值。
    public var subjectRaw: String = ""
    public var topic: String = ""
    /// 正文 Markdown，可以有公式、化学式、组件和引用角标。
    public var content: String = ""
    public var componentStateJSON: String = ""
    /// 出处（`[WebSource]` 的 JSON），编号和正文里的角标一致。
    public var sourcesJSON: String = ""
    public var modelName: String = ""
    public var sourceConversationID: UUID?

    public init(title: String, content: String) {
        self.title = title
        self.content = content
    }

    public var subject: Subject? {
        get { Subject(rawValue: subjectRaw) }
        set { subjectRaw = newValue?.rawValue ?? "" }
    }

    public var sources: [WebSource] {
        get {
            guard !sourcesJSON.isEmpty else { return [] }
            return (try? JSONDecoder().decode([WebSource].self, from: Data(sourcesJSON.utf8))) ?? []
        }
        set {
            sourcesJSON = newValue.isEmpty ? "" : String(decoding: (try? JSONEncoder().encode(newValue)) ?? Data(), as: UTF8.self)
        }
    }
}
