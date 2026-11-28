import Foundation
import StudyKit
import SwiftData

/// 工具原文只活在这一轮请求里；回答、引用和用量存入普通消息。
@MainActor
final class StudyAssistantReply {
    private struct OutputLimit: Error {}
    private let reply: Message
    private let toolbox: StudyAssistantToolbox
    private let price: ModelPrice?
    private let rate: Double
    private let onActivity: @MainActor (String) -> Void
    private let onProgress: @MainActor () -> Void
    private var outputCount = 0
    private var startsNewTurn = false

    init(reply: Message, context: ModelContext, conversationID: UUID, price: ModelPrice?, rate: Double,
         hiddenIDs: @escaping @MainActor () -> Set<PersistentIdentifier> = { [] },
         onActivity: @escaping @MainActor (String) -> Void = { _ in },
         onProgress: @escaping @MainActor () -> Void = {}) {
        self.reply = reply
        self.price = price
        self.rate = rate
        self.onActivity = onActivity
        self.onProgress = onProgress
        toolbox = StudyAssistantToolbox(context: context, conversationID: conversationID,
                                        references: reply.studyReferences, hiddenIDs: hiddenIDs)
    }

    /// false 表示到达本轮内容长度上限，已保留当前内容。
    func run(service: any ChatService, request: ChatRequest) async throws -> Bool {
        let prefix = reply.content
        onActivity("正在查找学习内容…")
        defer { reply.studyReferences = toolbox.references }
        do {
            let result = try await ToolLoop(maxCalls: nil).run(
                service: service, request: StudyAssistantTools.prepare(request),
                onEvent: { event in try await self.receive(event) },
                onUsage: { usage in await self.record(usage) },
                execute: { call in try await self.execute(call) }
            )
            try Task.checkCancellation()
            if case let .answered(answer) = result.ending {
                guard !answer.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                    throw StudyAssistantTools.ArgumentError("模型没有给出回答，请重试或换一个模型。")
                }
                reply.content = prefix + (prefix.isEmpty ? "" : "\n\n") + answer
                return true
            }
            // 不限制调用次数，工具只会在累计读取内容过长时主动停止。
            append("本轮读取内容已达到上限，已保留读到的资料。可以缩小范围后继续提问。")
        } catch is OutputLimit {
            append("本轮输出较长，已停止并保留现有内容。")
        }
        return false
    }

    private func receive(_ event: ChatStreamEvent) throws {
        try Task.checkCancellation()
        let length: Int
        switch event {
        case let .text(value), let .reasoning(value): length = value.count
        case let .toolCall(call): length = call.arguments.count
        case let .thinkingBlock(block): length = block.text.count + (block.signature?.count ?? 0) + (block.redactedData?.count ?? 0)
        default: length = 0
        }
        outputCount += length
        guard outputCount <= StudyAssistantTools.maxOutputLength else { throw OutputLimit() }
        switch event {
        case let .text(delta):
            if startsNewTurn && !delta.isEmpty {
                if !reply.content.isEmpty { reply.content += "\n\n" }
                startsNewTurn = false
            }
            reply.content += delta
        case let .reasoning(delta): reply.reasoning += delta
        default: break
        }
        onProgress()
    }

    private func execute(_ call: ToolCall) async throws -> ToolLoop.Outcome {
        startsNewTurn = true
        onActivity(call.name == "search_study_records" ? "正在查找学习内容…" : "正在阅读原记录…")
        let result = try await toolbox.execute(call)
        reply.studyReferences = toolbox.references
        onActivity("正在整理回答…")
        return result
    }

    private func record(_ usage: ToolLoop.Usage) {
        if let input = usage.input { reply.inputTokens = (reply.inputTokens ?? 0) + input }
        if let output = usage.output { reply.outputTokens = (reply.outputTokens ?? 0) + output }
        reply.cachedInputTokens = (reply.cachedInputTokens ?? 0) + usage.cachedInput
        if let price, usage.input != nil || usage.output != nil {
            reply.costCNY = (reply.costCNY ?? 0) + price.costCNY(
                inputTokens: usage.input ?? 0, cachedInputTokens: usage.cachedInput, outputTokens: usage.output ?? 0,
                webSearches: usage.searches, usdToCNY: rate, at: usage.started
            )
        }
    }

    private func append(_ text: String) {
        reply.content += (reply.content.isEmpty ? "" : "\n\n") + text
    }
}
