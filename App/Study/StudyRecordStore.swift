import Foundation
import StudyKit
import SwiftData

/// 本地记录的定位与文字读取，工具和引用页面共用。
@MainActor
enum StudyRecord {
    case conversation(Conversation)
    case mistake(Mistake)
    case card(ConceptCard)
    case compilation(Compilation)
    case question(ExamQuestion)

    var model: any PersistentModel {
        switch self {
        case let .conversation(value): value
        case let .mistake(value): value
        case let .card(value): value
        case let .compilation(value): value
        case let .question(value): value
        }
    }

    var kind: StudyRecordKind {
        switch self {
        case .conversation: .conversation
        case .mistake: .mistake
        case .card: .card
        case .compilation: .compilation
        case .question: .question
        }
    }

    var id: UUID {
        switch self {
        case let .conversation(value): value.id
        case let .mistake(value): value.id
        case let .card(value): value.id
        case let .compilation(value): value.id
        case let .question(value): value.id
        }
    }

    var title: String {
        switch self {
        case let .conversation(value): value.title
        case let .mistake(value): String((value.topic.isEmpty ? value.previewText : value.topic).prefix(100))
        case let .card(value): value.title
        case let .compilation(value): value.title
        case let .question(value): value.label
        }
    }

    var subject: String {
        switch self {
        case .conversation: ""
        case let .mistake(value): value.subjectRaw
        case let .card(value): value.subjectRaw
        case let .compilation(value): value.subjectRaw
        case let .question(value): value.compilation?.subjectRaw ?? ""
        }
    }

    var topic: String {
        switch self {
        case .conversation, .compilation: ""
        case let .mistake(value): value.topic
        case let .card(value): value.topic
        case let .question(value): value.groupName
        }
    }

    var date: Date {
        switch self {
        case let .conversation(value): value.updatedAt
        case let .mistake(value): value.createdAt
        case let .card(value): value.updatedAt
        case let .compilation(value): value.updatedAt
        case let .question(value): value.createdAt
        }
    }

    func isAvailable(hiddenIDs: Set<PersistentIdentifier>, excluding conversationID: UUID? = nil) -> Bool {
        guard !model.isDeleted, !hiddenIDs.contains(model.persistentModelID) else { return false }
        if case let .conversation(value) = self { return value.id != conversationID }
        if case let .question(value) = self {
            guard let parent = value.compilation else { return false }
            return !parent.isDeleted && !hiddenIDs.contains(parent.persistentModelID)
        }
        return true
    }

    /// 仅提供文字和图片存在提示，不把二进制附件伪装成已识别内容。
    var text: String {
        switch self {
        case let .conversation(value):
            return value.sortedMessages.filter { $0.status != .streaming && $0.status != .failed }.map { message in
                let role = message.role == .user ? "用户" : "模型"
                let images = message.attachments?.count ?? 0
                let mark = images > 0 ? "\n[附件：\(images) 张图片，未读取图像]" : ""
                return "\(role)（\(message.createdAt.ISO8601Format())）：\n\(message.content)\(mark)"
            }.joined(separator: "\n\n")
        case let .mistake(value):
            let question = value.kind == .quiz ? value.questionJSON : value.questionText
            let images = (value.images?.count ?? 0) + (value.storedImages?.count ?? 0)
            return """
            题目：\(question)
            当时作答：\(value.wrongAnswerJSON.isEmpty ? "没有保存文字作答" : value.wrongAnswerJSON)
            解答：\(value.solution)
            备注：\(value.note)
            图片：\(images) 张，未读取图像。
            复习方式：\(value.kind == .manual ? "用户自评" : "测验判分")
            已复习 \(value.reviewCount) 次；当前第 \(value.box + 1) 档；\(value.isMastered ? "已掌握" : "待复习")。
            最近复习：\(value.lastReviewedAt?.ISO8601Format() ?? "尚未复习")；下次复习：\(value.dueAt.ISO8601Format())。
            """
        case let .card(value):
            let sources = value.sources.enumerated().map { "[\($0.offset + 1)] \($0.element.title) \($0.element.url)" }.joined(separator: "\n")
            return [value.content, value.example.isEmpty ? "" : "例子：\n" + value.example, sources].filter { !$0.isEmpty }.joined(separator: "\n\n")
        case let .compilation(value):
            let questions = value.sortedQuestions.map { "\($0.label)；id=\($0.id.uuidString)；知识点：\($0.groupName)；状态：\($0.statusRaw)" }
            return (["要求：\(value.request)", "状态：\(value.statusRaw)", "原题目录（使用 question 类型逐题读取）："] + questions).joined(separator: "\n")
        case let .question(value):
            return """
            \(value.label)
            状态：\(value.statusRaw)；\(value.reviewRejected ? "曾被复核拒绝，请核对原文" : "请以所附原文为准")
            复核备注：\(value.reviewNote)
            题目：\(value.content)
            答案与解析（\(value.answerKindRaw)）：\(value.answer)
            出处：\(value.sourceURL)
            图片：\(value.images?.count ?? 0) 张，未读取图像。题干中的 sa-asset 引用仅用于 App 展示。
            """
        }
    }
}

@MainActor
enum StudyRecordStore {
    static func all(_ kind: StudyRecordKind, in context: ModelContext) throws -> [StudyRecord] {
        switch kind {
        case .conversation: try context.fetch(FetchDescriptor<Conversation>()).map(StudyRecord.conversation)
        case .mistake: try context.fetch(FetchDescriptor<Mistake>()).map(StudyRecord.mistake)
        case .card: try context.fetch(FetchDescriptor<ConceptCard>()).map(StudyRecord.card)
        case .compilation: try context.fetch(FetchDescriptor<Compilation>()).map(StudyRecord.compilation)
        case .question: try context.fetch(FetchDescriptor<ExamQuestion>()).map(StudyRecord.question)
        }
    }

    static func find(kind: StudyRecordKind, id: UUID, in context: ModelContext) throws -> StudyRecord? {
        switch kind {
        case .conversation:
            try context.fetch(FetchDescriptor<Conversation>(predicate: #Predicate { $0.id == id })).first.map(StudyRecord.conversation)
        case .mistake:
            try context.fetch(FetchDescriptor<Mistake>(predicate: #Predicate { $0.id == id })).first.map(StudyRecord.mistake)
        case .card:
            try context.fetch(FetchDescriptor<ConceptCard>(predicate: #Predicate { $0.id == id })).first.map(StudyRecord.card)
        case .compilation:
            try context.fetch(FetchDescriptor<Compilation>(predicate: #Predicate { $0.id == id })).first.map(StudyRecord.compilation)
        case .question:
            try context.fetch(FetchDescriptor<ExamQuestion>(predicate: #Predicate { $0.id == id })).first.map(StudyRecord.question)
        }
    }
}
