import Foundation
import Observation
import StudyKit
import SwiftData

/// 资料页持有会话，工具读取的全文仅保留在当前任务中。
@MainActor
@Observable
final class LibraryAssistant {
    struct Message: Identifiable {
        let id = UUID()
        let role: ChatRole
        var text: String
    }

    static let historyLimit = 8
    static let historyTextLimit = 2_000
    static let outputLimit = 64_000
    static let toolResultLimit = 240_000

    private(set) var messages: [Message] = []
    private(set) var isRunning = false
    private(set) var activity = ""
    private(set) var errorMessage: String?
    var selectedModel: ChatModel?
    private(set) var costCNY = 0.0
    private(set) var changes: [LibraryAssistantChange] = []

    @ObservationIgnored private let serviceOverride: (any ChatService)?
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var runID: UUID?
    @ObservationIgnored private var replyID: UUID?
    @ObservationIgnored private var outputCount = 0
    @ObservationIgnored private var toolResultBytes = 0
    @ObservationIgnored private var outputLimited = false
    @ObservationIgnored private var contextLimited = false
    @ObservationIgnored private var startsNewReplyTurn = false

    init(service: (any ChatService)? = nil) {
        serviceOverride = service
    }

    @discardableResult
    func send(_ text: String, context: ModelContext, scopeDescription: String = "全部资料") -> Task<Void, Never>? {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !isRunning, !text.isEmpty else { return nil }
        errorMessage = nil
        guard let model = selectedModel ?? ModelLookup.defaultModel(in: context) else {
            errorMessage = GenerationError.noModel.localizedDescription
            return nil
        }
        let service: any ChatService
        do {
            service = try serviceOverride ?? ModelLookup.service(for: model)
        } catch {
            errorMessage = ChatErrorDescription.describe(error)
            return nil
        }
        selectedModel = model
        let previous = messages.filter { !$0.text.isEmpty }.suffix(Self.historyLimit - 1)
            .drop(while: { $0.role != .user }).map {
            ChatMessage(role: $0.role, text: Self.shortHistory($0.text))
        }
        let request = LibraryAssistantTools.request(
            model: model.modelID,
            messages: previous + [ChatMessage(role: .user, text: text)],
            scopeDescription: scopeDescription
        )
        messages.append(Message(role: .user, text: text))
        let reply = Message(role: .assistant, text: "")
        messages.append(reply)
        replyID = reply.id
        outputCount = 0
        toolResultBytes = 0
        outputLimited = false
        contextLimited = false
        startsNewReplyTurn = false
        let id = UUID()
        runID = id
        isRunning = true
        activity = "正在查看资料…"
        let initialChanges = changes.count
        let price = model.price()
        let rate = AppSettingsKey.usdToCNYRate
        // 每条新指令重新读取，不能沿用上轮对旧版本的写入授权。
        let toolbox = LibraryAssistantToolbox(context: context, modelName: model.name) { [weak self] change in
            self?.changes.append(change)
        }
        let work = Task { [self] in
            defer {
                if runID == id {
                    isRunning = false
                    activity = ""
                    task = nil
                    runID = nil
                    replyID = nil
                }
            }
            do {
                let result = try await ToolLoop(maxCalls: LibraryAssistantTools.maxCalls).run(
                    service: service,
                    request: request,
                    onEvent: { [weak self] event in await self?.receive(event, run: id) },
                    onUsage: { [weak self] usage in
                        await self?.record(usage, price: price, rate: rate, run: id)
                    },
                    execute: { [weak self] call in
                        await self?.setActivity(for: call, run: id)
                        let outcome = try await toolbox.execute(call)
                        return await self?.limit(outcome, run: id) ?? outcome
                    }
                )
                try Task.checkCancellation()
                switch result.ending {
                case let .answered(answer):
                    replaceReply(answer.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                        ? completionText(since: initialChanges) : answer)
                case .stopped:
                    appendReply(contextLimited
                        ? "本轮读取的资料较多，已停止。" + completionText(since: initialChanges)
                        : completionText(since: initialChanges))
                case .limitReached:
                    appendReply("本轮已达到操作上限。" + completionText(since: initialChanges))
                }
            } catch {
                if Task.isCancelled || error is CancellationError {
                    appendReply((outputLimited ? "本轮输出较长，已停止。" : "已停止。") + completionText(since: initialChanges))
                } else {
                    let description = error as? ToolLoopError == .toolsUnsupported
                        ? "这个模型不支持工具调用，资料助手需要换一个支持工具调用的模型。"
                        : ChatErrorDescription.describe(error)
                    errorMessage = description
                    appendReply("本轮未能完成。" + completionText(since: initialChanges))
                }
            }
        }
        task = work
        return work
    }

    func stop() {
        guard isRunning else { return }
        activity = "正在停止…"
        task?.cancel()
    }

    func undoLast(context: ModelContext) {
        guard !isRunning, let change = changes.last else { return }
        errorMessage = nil
        do {
            try change.undo(in: context)
            changes.removeLast()
            messages.append(Message(role: .assistant, text: "已撤销最近操作：\(change.summary)"))
        } catch {
            errorMessage = ChatErrorDescription.describe(error)
        }
    }

    private static func shortHistory(_ text: String) -> String {
        guard text.count > historyTextLimit else { return text }
        return String(text.prefix(historyTextLimit - 1)) + "…"
    }

    private func receive(_ event: ChatStreamEvent, run id: UUID) {
        guard runID == id else { return }
        let length: Int
        switch event {
        case let .text(text), let .reasoning(text): length = text.count
        case let .toolCall(call): length = call.arguments.count
        case let .thinkingBlock(block): length = block.text.count + (block.signature?.count ?? 0) + (block.redactedData?.count ?? 0)
        default: length = 0
        }
        outputCount += length
        guard outputCount <= Self.outputLimit else {
            outputLimited = true
            task?.cancel()
            return
        }
        if case let .text(delta) = event,
           let index = messages.firstIndex(where: { $0.id == replyID }) {
            guard !delta.isEmpty else { return }
            if startsNewReplyTurn {
                if !messages[index].text.isEmpty { messages[index].text += "\n\n" }
                startsNewReplyTurn = false
            }
            messages[index].text += delta
        }
    }

    private func setActivity(for call: ToolCall, run id: UUID) {
        guard runID == id else { return }
        startsNewReplyTurn = true
        activity = switch LibraryAssistantTools.Name(rawValue: call.name) {
        case .listCards: "正在查找知识卡…"
        case .readCards: "正在阅读知识卡…"
        case .updateCards: "正在整理知识卡…"
        case .mergeCards: "正在合并知识卡…"
        case .listNotes: "正在查找原资料…"
        case .readNote: "正在阅读原资料…"
        case .organizeNote: "正在拆分原资料…"
        case nil: "正在处理…"
        }
    }

    private func limit(_ outcome: ToolLoop.Outcome, run id: UUID) -> ToolLoop.Outcome {
        guard runID == id else { return outcome }
        toolResultBytes += outcome.content.utf8.count
        guard toolResultBytes <= Self.toolResultLimit else {
            contextLimited = true
            return ToolLoop.Outcome(content: "本轮读取内容已达到上限。", stop: true)
        }
        return outcome
    }

    private func record(_ usage: ToolLoop.Usage, price: ModelPrice?, rate: Double, run id: UUID) {
        guard runID == id, let price else { return }
        costCNY += price.costCNY(
            inputTokens: usage.input ?? 0, cachedInputTokens: usage.cachedInput, outputTokens: usage.output ?? 0,
            webSearches: usage.searches, usdToCNY: rate, at: usage.started
        )
    }

    private func completionText(since count: Int) -> String {
        let completed = changes.count - count
        return completed > 0 ? "已保存 \(completed) 项操作，可撤销。" : "本轮没有修改资料。"
    }

    private func replaceReply(_ text: String) {
        guard let index = messages.firstIndex(where: { $0.id == replyID }) else { return }
        messages[index].text = text
    }

    private func appendReply(_ text: String) {
        guard let index = messages.firstIndex(where: { $0.id == replyID }) else { return }
        messages[index].text += (messages[index].text.isEmpty ? "" : "\n\n") + text
    }
}
