import CryptoKit
import Foundation
import SwiftData

// 错题、收藏和学习记录。和其他模型一样遵守 CloudKit 的约束（见 docs/adr/0004）。
// 错题和收藏都保存独立副本（见 docs/adr/0009）。

public enum MistakeKind: String, Sendable {
    /// 测验里答错的题，可以在本地判分。
    case quiz
    /// 用户手动加入的题：自己的提问加上 AI 的解答，由用户自己判断会没会。
    case manual
}

/// 错题本里的一道题。
@Model
public final class Mistake {
    public var id: UUID = UUID()
    public var createdAt: Date = Date()
    public var kindRaw: String = MistakeKind.quiz.rawValue

    /// 科目，`Subject` 的原始值。空字符串表示还没分类（等模型补）。
    public var subjectRaw: String = ""
    public var topic: String = ""

    /// 测验题：单道题的 JSON（core.js 的 quizQuestionToJSON）。
    public var questionJSON: String = ""
    /// 测验题：答错时的作答，测验组件的状态格式，例如 {"choice":[0]}。
    public var wrongAnswerJSON: String = ""
    /// 手动加入的题：用户提问的文字。
    public var questionText: String = ""
    /// 手动加入的题：AI 的解答（Markdown，可以含组件）和组件状态。
    public var solution: String = ""
    public var solutionStateJSON: String = ""
    public var note: String = ""

    /// 用来避免同一道测验题重复加入。
    public var dedupeKey: String = ""

    /// 来源，用来跳回原会话。原会话可能已经删除。
    public var sourceConversationID: UUID?
    public var sourceMessageID: UUID?

    /// 复习进度（见 ReviewSchedule）。
    public var box: Int = 0
    public var dueAt: Date = Date()
    public var masteredAt: Date?
    public var lastReviewedAt: Date?
    public var reviewCount: Int = 0

    @Relationship(deleteRule: .cascade, inverse: \MistakeImage.mistake)
    public var images: [MistakeImage]? = []

    /// 从汇编加入的原题：题目和解答 Markdown 里 `sa-asset:` 引用的图片（独立副本）。
    @Relationship(deleteRule: .cascade, inverse: \StoredImage.mistake)
    public var storedImages: [StoredImage]? = []

    public init(kind: MistakeKind) {
        self.kindRaw = kind.rawValue
    }

    public var kind: MistakeKind {
        MistakeKind(rawValue: kindRaw) ?? .quiz
    }

    public var subject: Subject? {
        get { Subject(rawValue: subjectRaw) }
        set { subjectRaw = newValue?.rawValue ?? "" }
    }

    public var isMastered: Bool { masteredAt != nil }

    public var imageData: [Data] {
        (images ?? []).sorted { $0.index < $1.index }.compactMap(\.data)
    }

    /// 测验题的 Markdown：一个只有这一道题的测验组件，复习和查看时用。
    public var quizMarkdown: String {
        "```quiz\n{\"questions\":[\(questionJSON)]}\n```"
    }

    /// 测验题的题目文字，用于列表预览和搜索。
    public var previewText: String {
        if kind == .manual { return questionText }
        guard let object = try? JSONSerialization.jsonObject(with: Data(questionJSON.utf8)) as? [String: Any] else {
            return ""
        }
        return object["question"] as? String ?? ""
    }

    /// 测验题的去重键：题目和选项相同就算同一道题。
    public static func dedupeKey(forQuestionJSON json: String) -> String {
        var source = json
        if let object = try? JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any] {
            let question = (object["question"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            let options = (object["options"] as? [String] ?? []).joined(separator: "\u{1F}")
            source = question + "\u{1E}" + options
        }
        let digest = SHA256.hash(data: Data(source.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }
}

@Model
public final class MistakeImage {
    public var id: UUID = UUID()
    @Attribute(.externalStorage) public var data: Data?
    public var index: Int = 0
    public var mistake: Mistake?

    public init(data: Data, index: Int) {
        self.data = data
        self.index = index
    }
}

/// 收藏的一整条回答。
@Model
public final class Bookmark {
    public var id: UUID = UUID()
    public var createdAt: Date = Date()
    public var title: String = ""
    public var subjectRaw: String = ""
    public var topic: String = ""
    public var content: String = ""
    public var componentStateJSON: String = ""
    public var modelName: String = ""
    public var sourceConversationID: UUID?
    public var sourceMessageID: UUID?

    public init(title: String, content: String) {
        self.title = title
        self.content = content
    }

    public var subject: Subject? {
        get { Subject(rawValue: subjectRaw) }
        set { subjectRaw = newValue?.rawValue ?? "" }
    }
}

public enum StudyEventKind: String, Sendable {
    /// 在会话里做测验。
    case quiz
    /// 复习错题。
    case review
}

/// 一次作答记录，用于学习记录的统计。
@Model
public final class StudyEvent {
    public var id: UUID = UUID()
    public var date: Date = Date()
    public var kindRaw: String = StudyEventKind.quiz.rawValue
    public var correct: Bool = false
    public var subjectRaw: String = ""
    public var topic: String = ""

    public init(kind: StudyEventKind, correct: Bool, subject: String, topic: String, date: Date = .now) {
        self.kindRaw = kind.rawValue
        self.correct = correct
        self.subjectRaw = subject
        self.topic = topic
        self.date = date
    }
}

/// 所有需要放进 ModelContainer 的模型。
public enum StudyAgentSchema {
    public static let models: [any PersistentModel.Type] = [
        Provider.self, ChatModel.self, Conversation.self, Message.self, Attachment.self,
        Mistake.self, MistakeImage.self, Bookmark.self, StudyEvent.self,
        ResearchNote.self, Compilation.self, ExamQuestion.self, StoredImage.self,
        ConceptCard.self, ConceptLink.self,
    ]
}
