import Foundation
import Observation
import StudyKit
import SwiftData

/// 侧边栏里选中的项目。
enum SidebarItem: Hashable {
    case conversation(Conversation)
    case mistakes
    case bookmarks
    case stats
}

/// 侧边栏的选择放在环境里，错题本、收藏等页面也能跳到某个会话。
@MainActor
@Observable
final class AppNavigation {
    var selection: SidebarItem?

    func open(conversationID: UUID?, in context: ModelContext) -> Bool {
        guard let id = conversationID else { return false }
        let descriptor = FetchDescriptor<Conversation>(predicate: #Predicate { $0.id == id })
        guard let conversation = try? context.fetch(descriptor).first else { return false }
        selection = .conversation(conversation)
        return true
    }
}

/// 错题本和学习记录的写入：测验作答、手动加入错题、给错题和收藏补科目。
@MainActor
enum StudyCenter {
    // MARK: - 测验作答

    /// 会话里的测验答完一道题：记一条学习记录；答错时加入错题本（同一道题不重复加入，只重置档位）。
    static func recordQuizResult(
        _ payload: [String: Any],
        conversation: Conversation,
        message: Message,
        context: ModelContext
    ) {
        guard let question = payload["question"] as? [String: Any],
              JSONSerialization.isValidJSONObject(question),
              let questionData = try? JSONSerialization.data(withJSONObject: question, options: [.sortedKeys]),
              let answer = payload["answer"] as? [String: Any],
              let answerData = try? JSONSerialization.data(withJSONObject: answer, options: [.sortedKeys])
        else { return }
        let correct = (payload["correct"] as? NSNumber)?.boolValue ?? false
        let subject = Subject.normalize(question["subject"] as? String ?? "")
        let topic = (question["topic"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)

        context.insert(StudyEvent(kind: .quiz, correct: correct, subject: subject?.rawValue ?? "", topic: topic))

        guard !correct else {
            try? context.save()
            return
        }

        let questionJSON = String(decoding: questionData, as: UTF8.self)
        let key = Mistake.dedupeKey(forQuestionJSON: questionJSON)
        let descriptor = FetchDescriptor<Mistake>(predicate: #Predicate { $0.dedupeKey == key })
        if let existing = try? context.fetch(descriptor).first {
            existing.wrongAnswerJSON = String(decoding: answerData, as: UTF8.self)
            ReviewSchedule.reset(existing)
            try? context.save()
            return
        }

        let mistake = Mistake(kind: .quiz)
        mistake.questionJSON = questionJSON
        mistake.wrongAnswerJSON = String(decoding: answerData, as: UTF8.self)
        mistake.dedupeKey = key
        mistake.subject = subject
        mistake.topic = topic
        mistake.sourceConversationID = conversation.id
        mistake.sourceMessageID = message.id
        ReviewSchedule.reset(mistake)
        context.insert(mistake)
        try? context.save()

        if subject == nil || topic.isEmpty {
            classify(mistake, content: question["question"] as? String ?? "", model: conversation.model, context: context)
        }
    }

    // MARK: - 手动加入

    /// 把用户的一条提问和后面那条 AI 解答加入错题本。
    static func addManualMistake(
        question: Message,
        solution: Message,
        note: String,
        conversation: Conversation,
        context: ModelContext
    ) {
        let mistake = Mistake(kind: .manual)
        mistake.questionText = question.content
        mistake.solution = solution.content
        mistake.solutionStateJSON = solution.componentStateJSON
        mistake.note = note.trimmingCharacters(in: .whitespacesAndNewlines)
        mistake.sourceConversationID = conversation.id
        mistake.sourceMessageID = question.id
        ReviewSchedule.reset(mistake)
        context.insert(mistake)
        for (index, data) in question.imageData.enumerated() {
            let image = MistakeImage(data: data, index: index)
            context.insert(image)
            image.mistake = mistake
        }
        try? context.save()

        let content = question.content.isEmpty
            ? "（题目是一张图片）解答：\n" + solution.content
            : question.content + "\n\n解答：\n" + solution.content
        classify(mistake, content: content, model: conversation.model, context: context)
    }

    // MARK: - 补科目和知识点

    static func classify(_ mistake: Mistake, content: String, model: ChatModel?, context: ModelContext) {
        Task {
            let result = await classification(for: content, model: model ?? ModelLookup.defaultModel(in: context))
            if mistake.subject == nil { mistake.subject = result?.subject ?? .other }
            if mistake.topic.isEmpty { mistake.topic = result?.topic ?? "未分类" }
            try? context.save()
        }
    }

    static func classify(_ bookmark: Bookmark, model: ChatModel?, context: ModelContext) {
        Task {
            let content = PlainTextExporter.plainText(from: bookmark.content)
            let result = await classification(for: content, model: model ?? ModelLookup.defaultModel(in: context))
            if bookmark.subject == nil { bookmark.subject = result?.subject ?? .other }
            if bookmark.topic.isEmpty { bookmark.topic = result?.topic ?? "未分类" }
            try? context.save()
        }
    }

    /// 请模型分类。没有模型、请求失败或输出看不懂时返回 nil。
    private static func classification(for content: String, model: ChatModel?) async -> (subject: Subject, topic: String)? {
        guard let model, let provider = model.provider,
              let service = try? ChatServiceFactory.makeService(
                  kind: provider.kind,
                  baseURL: provider.baseURL,
                  apiKey: KeychainStore.apiKey(for: provider.id) ?? ""
              )
        else { return nil }
        var raw = ""
        do {
            for try await event in service.streamChat(SubjectClassifier.request(model: model.modelID, content: content)) {
                if case let .text(delta) = event { raw += delta }
                if raw.count > 400 { break }
            }
        } catch {
            return nil
        }
        return SubjectClassifier.parse(raw)
    }

    // MARK: - 新会话

    /// 新建一个会话并发出一条消息，例如"再来几道类似的"。返回 false 表示没有可用的模型。
    @discardableResult
    static func startConversation(
        title: String,
        prompt: String,
        context: ModelContext,
        generation: GenerationCenter,
        navigation: AppNavigation
    ) throws -> Bool {
        guard let model = ModelLookup.defaultModel(in: context) else { throw GenerationError.noModel }
        let conversation = Conversation(title: title)
        conversation.titleIsAutomatic = false
        context.insert(conversation)
        conversation.model = model
        try context.save()
        try generation.send(prompt, in: conversation, context: context)
        navigation.selection = .conversation(conversation)
        return true
    }
}
