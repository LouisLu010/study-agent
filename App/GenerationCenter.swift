import Foundation
import Observation
import StudyKit
import SwiftData

enum GenerationError: LocalizedError {
    case noModel

    var errorDescription: String? {
        switch self {
        case .noModel: "请先在设置里添加模型，再为这个会话选择模型。"
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

    /// 发送一条用户消息，并开始流式生成模型的回答。
    func send(_ text: String, in conversation: Conversation, context: ModelContext) throws {
        guard tasks[conversation.id] == nil else { return }
        guard let model = conversation.model, let provider = model.provider else {
            throw GenerationError.noModel
        }
        let service = try ChatServiceFactory.makeService(
            kind: provider.kind,
            baseURL: provider.baseURL,
            apiKey: KeychainStore.apiKey(for: provider.id) ?? ""
        )

        let nextIndex = (conversation.sortedMessages.last?.index ?? -1) + 1

        let userMessage = Message(role: .user, content: text, index: nextIndex)
        context.insert(userMessage)
        userMessage.conversation = conversation

        let request = ChatRequest(
            model: model.modelID,
            systemPrompt: SystemPrompt.compose(
                customInstructions: UserDefaults.standard.string(forKey: AppSettingsKey.customInstructions) ?? ""
            ),
            messages: conversation.chatHistory(),
            reasoningEffort: model.reasoningEffort
        )

        let reply = Message(role: .assistant, status: .streaming, index: nextIndex + 1)
        context.insert(reply)
        reply.conversation = conversation

        conversation.updatedAt = .now
        try? context.save()

        let conversationID = conversation.id
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
                    reply.errorText = error.localizedDescription
                }
            }
            conversation.updatedAt = .now
            try? context.save()
            self?.tasks[conversationID] = nil
        }
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
}
