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
    /// 被系统结束后台运行而停下的会话。它们的回答标为"被系统中断"，不算用户点了停止。
    @ObservationIgnored private var interruptedBySystem: Set<UUID> = []

    /// 让模型从断点接着写的固定说明。只放在这一次请求里，不保存成消息。
    static let continuePrompt = "（上一条回答写到一半被系统中断了。请从中断的地方直接接着写，不要重复已经写过的内容，也不要加开场白或说明。）"

    func isGenerating(_ conversation: Conversation) -> Bool {
        tasks[conversation.id] != nil
    }

    /// 发送一条用户消息（文字和图片），并开始生成模型的回答。
    func send(_ text: String, images: [Data] = [], in conversation: Conversation, context: ModelContext) throws {
        guard tasks[conversation.id] == nil else { return }
        let service = try prepareService(for: conversation, hasImages: !images.isEmpty)

        // 继续对话后，上一条回答只保留当前选中的版本（见 docs/adr/0008）。
        conversation.sortedMessages.last { $0.role == .assistant }?.keepOnlyCurrentVersion()

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

    /// 重新生成最后一条模型回答（也用于失败后重试）。旧的回答作为另一个版本保留。
    func regenerate(_ reply: Message, in conversation: Conversation, context: ModelContext) throws {
        guard tasks[conversation.id] == nil, reply.role == .assistant else { return }
        let hasImages = conversation.sortedMessages.contains { !$0.imageData.isEmpty }
        let service = try prepareService(for: conversation, hasImages: hasImages)

        if conversation.sortedMessages.last?.id == reply.id {
            reply.beginNewVersion()
            startReply(in: conversation, service: service, context: context, into: reply)
        } else {
            deleteMessages(in: conversation, from: reply.index, context: context)
            startReply(in: conversation, service: service, context: context)
        }
    }

    /// 切换最后一条回答的版本。生成过程中不能切换。
    func selectVersion(_ index: Int, of reply: Message, in conversation: Conversation, context: ModelContext) {
        guard tasks[conversation.id] == nil else { return }
        reply.selectVersion(index)
        try? context.save()
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

    /// 被系统打断的最后一条回答：把已经写出的部分交回模型，让它接着写，写进同一条回答。
    /// 这一次不联网搜索（出处的编号和位置接不上）。
    func continueReply(_ reply: Message, in conversation: Conversation, context: ModelContext) throws {
        guard tasks[conversation.id] == nil, reply.role == .assistant, reply.status == .interrupted,
              conversation.sortedMessages.last?.id == reply.id
        else { return }
        let hasImages = conversation.sortedMessages.contains { !$0.imageData.isEmpty }
        let service = try prepareService(for: conversation, hasImages: hasImages)
        startReply(in: conversation, service: service, context: context, into: reply, continuing: true)
    }

    /// App 上次在生成过程中被关闭时，把残留的"生成中"消息标记为被中断，可以继续生成。
    func recoverInterruptedMessages(in context: ModelContext) {
        let streaming = MessageStatus.streaming.rawValue
        let descriptor = FetchDescriptor<Message>(predicate: #Predicate { $0.statusRaw == streaming })
        guard let messages = try? context.fetch(descriptor), !messages.isEmpty else { return }
        for message in messages where tasks[message.conversation?.id ?? UUID()] == nil {
            message.status = message.content.isEmpty ? .stopped : .interrupted
            message.finishVersion()
        }
        try? context.save()
    }

    /// 系统要结束后台运行：停下这个会话的生成，回答标为被中断。
    private func interruptBySystem(_ conversationID: UUID) {
        guard let task = tasks[conversationID] else { return }
        interruptedBySystem.insert(conversationID)
        task.cancel()
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

    /// 根据当前会话的历史开始流式生成。`existing` 为 nil 时插入一条新的模型消息，
    /// 否则写入这条消息（重新生成时，它已经通过 beginNewVersion 清空并标为生成中）。
    private func startReply(
        in conversation: Conversation,
        service: any ChatService,
        context: ModelContext,
        into existing: Message? = nil,
        continuing: Bool = false
    ) {
        guard let model = conversation.model else { return }

        // 只有会话打开了"联网"、模型也支持时才联网搜索。接着写被中断的回答时不搜索。
        let webSearch = !continuing && conversation.webSearchEnabled && model.supportsWebSearch
        // 历史里带着被中断的这条回答（已经写出的部分），后面加一句固定的说明。
        var history = conversation.chatHistory()
        if continuing {
            history.append(ChatMessage(role: .user, text: Self.continuePrompt))
            existing?.status = .streaming
            existing?.errorText = nil
        }
        let request = ChatRequest(
            model: model.modelID,
            systemPrompt: SystemPrompt.compose(
                customInstructions: UserDefaults.standard.string(forKey: AppSettingsKey.customInstructions) ?? "",
                conversationInstructions: conversation.instructions,
                simpleMode: UserDefaults.standard.bool(forKey: AppSettingsKey.simpleMode)
            ),
            messages: history,
            reasoningEffort: model.reasoningEffort,
            webSearch: webSearch,
            webSearchDialect: model.webSearchDialect
        )

        let reply: Message
        if let existing {
            reply = existing
        } else {
            let nextIndex = (conversation.sortedMessages.last?.index ?? -1) + 1
            reply = Message(role: .assistant, status: .streaming, index: nextIndex)
            context.insert(reply)
            reply.conversation = conversation
        }

        reply.modelName = model.name
        conversation.updatedAt = .now
        try? context.save()

        let conversationID = conversation.id
        let modelID = model.modelID
        // 生成开始时的单价；生成过程中换了模型也按这个算。
        let price = model.price()
        // DeepSeek 空闲时段半价，按开始的时间算。
        let started = Date.now
        // 接着写时，用量和费用加在原来的上面。
        let previous = continuing
            ? (input: reply.inputTokens ?? 0, cached: reply.cachedInputTokens ?? 0, output: reply.outputTokens ?? 0, cost: reply.costCNY ?? 0)
            : (input: 0, cached: 0, output: 0, cost: 0)
        if continuing {
            reply.inputTokens = nil
            reply.cachedInputTokens = nil
            reply.outputTokens = nil
        }

        // 切到别的 App 时也申请后台运行（第八版），和汇编共用 BackgroundKeeper，但是"轻"的工作。
        let keeper = BackgroundKeeper.shared
        let jobID = UUID()
        keeper.begin(id: jobID, title: "格物正在回答", subtitle: conversation.title, light: true) { [weak self] in
            self?.interruptBySystem(conversationID)
        }

        tasks[conversationID] = Task { [weak self] in
            var search = WebSearchRecorder()
            var events = 0
            do {
                for try await event in service.streamChat(request) {
                    switch event {
                    case let .text(delta): reply.content += delta
                    case let .reasoning(delta): reply.reasoning += delta
                    case let .usage(input, output):
                        if let input { reply.inputTokens = input }
                        if let output { reply.outputTokens = output }
                    case let .cachedInput(cached):
                        reply.cachedInputTokens = cached
                    case .searching, .searchResults, .citations, .searchCount:
                        if let marker = search.handle(event, content: reply.content) {
                            reply.content += marker
                        }
                        reply.webSearchJSON = search.record.encode()
                    case .toolCall, .thinkingBlock:
                        // 普通对话不声明工具，不会出现。
                        break
                    }
                    // 系统长任务要看到进度在走，否则会当成卡住结束它。
                    events += 1
                    if events % 40 == 0 {
                        let step = events / 40
                        keeper.update(id: jobID, completed: step, total: step + 1, subtitle: "已写 \(reply.content.count) 字")
                    }
                }
                if Task.isCancelled {
                    reply.status = self?.interruptedBySystem.contains(conversationID) == true ? .interrupted : .stopped
                } else {
                    reply.status = .complete
                }
            } catch {
                if self?.interruptedBySystem.contains(conversationID) == true {
                    reply.status = .interrupted
                } else if Task.isCancelled || error is CancellationError || (error as? URLError)?.code == .cancelled {
                    reply.status = .stopped
                } else if CompilationCenter.isBackgroundInterruption(error, since: started) {
                    // 切到后台被系统断开了连接：不算失败，保留写出的部分，可以继续生成。
                    reply.status = .interrupted
                } else {
                    reply.status = .failed
                    reply.errorText = ChatErrorDescription.describe(error)
                }
            }
            if reply.status == .interrupted && reply.content.isEmpty {
                // 一个字都还没写出来：没有可以接着写的，按失败处理，给"重试"。
                reply.status = .failed
                reply.errorText = "切到别的 App 后被系统中断了，还没有写出内容。"
            }
            // 按位置定位的引用（DeepSeek、Gemini）要等正文完整后再插角标。
            if webSearch || !search.record.isEmpty {
                reply.content = search.finish(content: reply.content)
                reply.webSearchJSON = search.record.encode()
            }
            if let price, reply.inputTokens != nil || reply.outputTokens != nil {
                let cost = price.costCNY(
                    inputTokens: reply.inputTokens ?? 0,
                    cachedInputTokens: reply.cachedInputTokens ?? 0,
                    outputTokens: reply.outputTokens ?? 0,
                    webSearches: search.record.effectiveCount,
                    usdToCNY: AppSettingsKey.usdToCNYRate,
                    at: started
                )
                reply.costCNY = previous.cost + cost
            }
            if continuing {
                reply.inputTokens = previous.input + (reply.inputTokens ?? 0)
                reply.cachedInputTokens = previous.cached + (reply.cachedInputTokens ?? 0)
                reply.outputTokens = previous.output + (reply.outputTokens ?? 0)
            }
            reply.finishVersion()
            conversation.updatedAt = .now
            try? context.save()
            self?.tasks[conversationID] = nil
            self?.interruptedBySystem.remove(conversationID)
            keeper.end(id: jobID, success: reply.status == .complete)

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
