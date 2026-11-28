import Foundation

public enum ToolLoopError: Error, Equatable, LocalizedError {
    case toolsUnsupported

    public var errorDescription: String? {
        switch self {
        case .toolsUnsupported: "这个模型不支持工具调用，汇编要换一个支持工具调用的模型。"
        }
    }
}

/// 工具循环：请模型回答 → 模型调用工具 → App 执行 → 把结果交回模型继续，直到某个工具说结束、
/// 模型不再调用工具，或者调用次数到了上限（见 docs/adr/0014）。三种协议共用，具体格式由各自的服务处理。
public struct ToolLoop: Sendable {
    /// 一次工具调用的执行结果。
    public struct Outcome: Sendable {
        /// 交给模型看的内容（通常是 JSON）。
        public var content: String
        /// 执行完这个工具后结束循环（例如"这份试卷完成"）。
        public var stop: Bool

        public init(content: String, stop: Bool = false) {
            self.content = content
            self.stop = stop
        }

        public init(_ value: JSONValue, stop: Bool = false) {
            self.init(content: value.jsonString, stop: stop)
        }
    }

    /// 一次请求的用量。
    public struct Usage: Sendable, Equatable {
        public var input: Int?
        public var cachedInput: Int
        public var output: Int?
        /// 服务商自带搜索的次数（工具循环里通常为 0）。
        public var searches: Int
        /// 请求开始的时间，用来按时段算价格。
        public var started: Date

        public init(input: Int? = nil, cachedInput: Int = 0, output: Int? = nil, searches: Int = 0, started: Date = .now) {
            self.input = input
            self.cachedInput = cachedInput
            self.output = output
            self.searches = searches
            self.started = started
        }
    }

    public enum Ending: Sendable, Equatable {
        /// 某个工具执行后要求结束。
        case stopped
        /// 模型没有调用工具就回答完了。
        case answered(String)
        /// 到了调用次数上限。
        case limitReached
    }

    public struct Result: Sendable {
        public var ending: Ending
        public var calls: Int
        /// 完整的对话，调试和测试用。
        public var messages: [ChatMessage]
    }

    public var maxCalls: Int
    /// 模型没调用工具就结束时，提醒它一次继续用工具（例如"请调用 finish_paper"）。为 nil 时直接结束。
    public var nudge: String?

    public init(maxCalls: Int, nudge: String? = nil) {
        self.maxCalls = maxCalls
        self.nudge = nudge
    }

    /// 运行循环。execute 抛出的错误（取消除外）当作这次调用失败交给模型；取消会直接抛出。
    public func run(
        service: any ChatService,
        request: ChatRequest,
        onEvent: @Sendable (ChatStreamEvent) async throws -> Void = { _ in },
        onUsage: @Sendable (Usage) async -> Void = { _ in },
        execute: @Sendable (ToolCall) async throws -> Outcome
    ) async throws -> Result {
        var request = request
        var calls = 0
        var nudged = false
        while true {
            try Task.checkCancellation()
            let turn: Turn
            do {
                turn = try await Self.stream(service: service, request: request, onEvent: onEvent)
                try Task.checkCancellation()
            } catch {
                // 第一次请求就因为工具被拒绝：多半是这个模型不支持工具调用。
                if calls == 0, Self.rejectsTools(error) { throw ToolLoopError.toolsUnsupported }
                throw error
            }
            // 即使是假服务或第三方适配器，也不能让损坏的参数进入执行器。
            for call in turn.toolCalls { _ = try call.validatedInput() }
            await onUsage(turn.usage)
            try Task.checkCancellation()
            request.messages.append(ChatMessage(
                role: .assistant, text: turn.text, toolCalls: turn.toolCalls, thinking: turn.thinking
            ))
            guard !turn.toolCalls.isEmpty else {
                if let nudge, !nudged {
                    nudged = true
                    request.messages.append(ChatMessage(role: .user, text: nudge))
                    continue
                }
                return Result(ending: .answered(turn.text), calls: calls, messages: request.messages)
            }
            var results: [ToolResult] = []
            var stop = false
            var limited = false
            for call in turn.toolCalls {
                try Task.checkCancellation()
                // 同一轮里到了上限的调用不执行，但也要给出结果，否则下一次请求格式不对。
                if stop || calls >= maxCalls {
                    limited = limited || (!stop && calls >= maxCalls)
                    results.append(ToolResult(callID: call.id, name: call.name, content: Self.skipped.jsonString))
                    continue
                }
                calls += 1
                let outcome: Outcome
                do {
                    outcome = try await execute(call)
                } catch is CancellationError {
                    throw CancellationError()
                } catch {
                    if Task.isCancelled { throw CancellationError() }
                    outcome = Outcome(["error": .string(ChatErrorDescription.describe(error))])
                }
                try Task.checkCancellation()
                results.append(ToolResult(callID: call.id, name: call.name, content: outcome.content))
                stop = stop || outcome.stop
            }
            request.messages.append(ChatMessage(role: .user, text: "", toolResults: results))
            if stop { return Result(ending: .stopped, calls: calls, messages: request.messages) }
            if limited || calls >= maxCalls {
                return Result(ending: .limitReached, calls: calls, messages: request.messages)
            }
        }
    }

    static let skipped: JSONValue = ["error": "没有执行：已经结束或到了调用次数上限"]

    /// 服务商的错误是不是在说不支持工具（函数）调用。
    static func rejectsTools(_ error: any Error) -> Bool {
        let message: String
        switch error as? ChatServiceError {
        case let .http(status, text?) where status == 400 || status == 422 || status == 404: message = text
        case let .server(text): message = text
        default: return false
        }
        let lower = message.lowercased()
        return ["tool", "function"].contains { lower.contains($0) } || lower.contains("工具")
    }

    struct Turn {
        var text = ""
        var thinking: [ThinkingBlock] = []
        var reasoning = ""
        var toolCalls: [ToolCall] = []
        var usage: Usage
    }

    /// 发一次请求，收集文字、思考、工具调用和用量。
    static func stream(
        service: any ChatService, request: ChatRequest, onEvent: @Sendable (ChatStreamEvent) async throws -> Void
    ) async throws -> Turn {
        var turn = Turn(usage: Usage())
        var recorder = WebSearchRecorder()
        for try await event in service.streamChat(request) {
            try Task.checkCancellation()
            try await onEvent(event)
            try Task.checkCancellation()
            switch event {
            case let .text(delta): turn.text += delta
            case let .reasoning(delta): turn.reasoning += delta
            case let .usage(input, output):
                if let input { turn.usage.input = input }
                if let output { turn.usage.output = output }
            case let .cachedInput(cached): turn.usage.cachedInput = cached
            case let .toolCall(call): turn.toolCalls.append(call)
            case let .thinkingBlock(block): turn.thinking.append(block)
            case .searching, .searchResults, .citations, .searchCount:
                _ = recorder.handle(event, content: turn.text)
            }
        }
        // AsyncThrowingStream 在取消时可能正常结束迭代。
        try Task.checkCancellation()
        turn.usage.searches = recorder.record.effectiveCount
        // OpenAI 兼容协议（DeepSeek）的思考内容没有单独的块，整段作为 reasoning_content 传回。
        // Anthropic 的思考块自带文字；Gemini 只传签名，思考摘要不用传回。
        if turn.thinking.isEmpty, !turn.reasoning.isEmpty {
            turn.thinking = [ThinkingBlock(text: turn.reasoning)]
        }
        return turn
    }
}
