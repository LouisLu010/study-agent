import Foundation
import Observation
import StudyKit
import SwiftData

enum GenerationError: LocalizedError {
    case noModel
    case modelDoesNotSupportImages

    var errorDescription: String? {
        switch self {
        case .noModel:
            "请先在设置里添加模型，再为这个会话选择模型。"
        case .modelDoesNotSupportImages:
            "当前模型不支持图片。请切换到支持图片的模型，或在设置里为这个模型打开\"支持图片输入\"。"
        }
    }
}

/// 管理所有会话的生成任务。放在 App 层级，切换会话时生成不会中断。
@MainActor
@Observable
final class GenerationCenter {
    private var tasks: [UUID: Task<Void, Never>] = [:]

    func isGenerating(_ conversation: Conversation) -> Bool {
        tasks[conversation.id] != nil
    }

    /// 发送一条用户消息（文字和图片），并开始生成模型的回答。
    func send(_ text: String, images: [Data] = [], in conversation: Conversation, context: ModelContext) throws {
        guard tasks[conversation.id] == nil else { return }
        let service = try prepareService(for: conversation, hasImages: !images.isEmpty)

        let nextIndex = (conversation.sortedMessages.last?.index ?? -1) + 1
        let userMessage = Message(role: .user, content: text, index: nextIndex)
        context.insert(userMessage)
        userMessage.conversation = conversation
        for (offset, data) in images.enumerated() {
            let attachment = Attachment(data: data, index: offset)
            context.insert(attachment)
            attachment.message = userMessage
        }

        startReply(in: conversation, service: service, context: context)
    }

    /// 重新生成最后一条模型回答（也用于失败后重试）。
    func regenerate(_ reply: Message, in conversation: Conversation, context: ModelContext) throws {
        guard tasks[conversation.id] == nil, reply.role == .assistant else { return }
        let hasImages = conversation.sortedMessages.contains { !$0.imageData.isEmpty }
        let service = try prepareService(for: conversation, hasImages: hasImages)

        deleteMessages(in: conversation, from: reply.index, context: context)
        startReply(in: conversation, service: service, context: context)
    }

    /// 修改一条用户消息的文字后重新发送：删掉它和之后的所有消息，保留原来的图片。
    func resend(_ userMessage: Message, newText: String, in conversation: Conversation, context: ModelContext) throws {
        guard tasks[conversation.id] == nil, userMessage.role == .user else { return }
        let images = userMessage.imageData
        _ = try prepareService(for: conversation, hasImages: !images.isEmpty)

        deleteMessages(in: conversation, from: userMessage.index, context: context)
        try send(newText, images: images, in: conversation, context: context)
    }

    func stop(_ conversation: Conversation) {
        tasks[conversation.id]?.cancel()
    }

    /// App 上次在生成过程中被关闭时，把残留的"生成中"消息标记为已停止。
    func recoverInterruptedMessages(in context: ModelContext) {
        let streaming = MessageStatus.streaming.rawValue
        let descriptor = FetchDescriptor<Message>(predicate: #Predicate { $0.statusRaw == streaming })
        guard let messages = try? context.fetch(descriptor), !messages.isEmpty else { return }
        for message in messages where tasks[message.conversation?.id ?? UUID()] == nil {
            message.status = .stopped
        }
        try? context.save()
    }

    // MARK: - 内部

    private func prepareService(for conversation: Conversation, hasImages: Bool) throws -> any ChatService {
        guard let model = conversation.model, let provider = model.provider else {
            throw GenerationError.noModel
        }
        if hasImages && !model.supportsImages {
            throw GenerationError.modelDoesNotSupportImages
        }
        return try ChatServiceFactory.makeService(
            kind: provider.kind,
            baseURL: provider.baseURL,
            apiKey: KeychainStore.apiKey(for: provider.id) ?? ""
        )
    }

    private func deleteMessages(in conversation: Conversation, from index: Int, context: ModelContext) {
        for message in conversation.sortedMessages where message.index >= index {
            context.delete(message)
        }
        // 立刻从关系里去掉，后面构造历史消息时不会再带上它们。
        conversation.messages?.removeAll { $0.index >= index }
    }

    /// 根据当前会话的历史，插入一条空的模型消息并开始流式生成。
    private func startReply(in conversation: Conversation, service: any ChatService, context: ModelContext) {
        guard let model = conversation.model else { return }

        let request = ChatRequest(
            model: model.modelID,
            systemPrompt: SystemPrompt.compose(
                customInstructions: UserDefaults.standard.string(forKey: AppSettingsKey.customInstructions) ?? ""
            ),
            messages: conversation.chatHistory(),
            reasoningEffort: model.reasoningEffort
        )

        let nextIndex = (conversation.sortedMessages.last?.index ?? -1) + 1
        let reply = Message(role: .assistant, status: .streaming, index: nextIndex)
        context.insert(reply)
        reply.conversation = conversation

        conversation.updatedAt = .now
        try? context.save()

        let conversationID = conversation.id
        let modelID = model.modelID
        tasks[conversationID] = Task { [weak self] in
            do {
                for try await event in service.streamChat(request) {
                    switch event {
                    case let .text(delta): reply.content += delta
                    case let .reasoning(delta): reply.reasoning += delta
                    }
                }
                reply.status = Task.isCancelled ? .stopped : .complete
            } catch {
                if Task.isCancelled || error is CancellationError || (error as? URLError)?.code == .cancelled {
                    reply.status = .stopped
                } else {
                    reply.status = .failed
                    reply.errorText = ChatErrorDescription.describe(error)
                }
            }
            conversation.updatedAt = .now
            try? context.save()
            self?.tasks[conversationID] = nil

            if reply.status == .complete {
                await Self.generateTitleIfNeeded(for: conversation, service: service, modelID: modelID, context: context)
            }
        }
    }

    /// 第一轮回答完成后自动生成会话标题。失败时保留"新会话"，不打扰用户。
    private static func generateTitleIfNeeded(
        for conversation: Conversation,
        service: any ChatService,
        modelID: String,
        context: ModelContext
    ) async {
        guard conversation.titleIsAutomatic, conversation.title == Conversation.defaultTitle else { return }
        let messages = conversation.sortedMessages
        guard let question = messages.first(where: { $0.role == .user }),
              let answer = messages.last(where: { $0.role == .assistant && $0.status == .complete })
        else { return }

        let questionText = question.content.isEmpty ? ConversationTitle.imageOnlyQuestion : question.content
        let request = ConversationTitle.request(model: modelID, question: questionText, answer: answer.content)
        var raw = ""
        do {
            for try await event in service.streamChat(request) {
                if case let .text(delta) = event {
                    raw += delta
                }
                if raw.count > 200 { break }
            }
        } catch {
            return
        }
        // 生成标题期间用户可能已经手动改了标题。
        guard conversation.titleIsAutomatic, let title = ConversationTitle.clean(raw) else { return }
        conversation.title = title
        try? context.save()
    }
}
