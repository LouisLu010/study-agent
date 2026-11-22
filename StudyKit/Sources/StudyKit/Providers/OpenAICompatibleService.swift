import Foundation

/// OpenAI Chat Completions 流式接口，也适用于 DeepSeek、通义千问、Kimi、OpenRouter 等兼容服务商。
public struct OpenAICompatibleService: ChatService {
    public let baseURL: URL
    public let apiKey: String
    private let session: URLSession

    public init(baseURL: URL, apiKey: String, session: URLSession = .shared) {
        self.baseURL = baseURL
        self.apiKey = apiKey
        self.session = session
    }

    // MARK: - 请求

    private struct RequestBody: Encodable {
        struct Message: Encodable {
            let role: String
            let content: Content
            /// assistant 发起的工具调用。
            var toolCalls: [OutgoingCall]? = nil
            /// tool 消息对应的调用 ID。
            var toolCallID: String? = nil
            /// DeepSeek 思考模式下调用工具，之前每一轮的思考内容都要传回去，否则返回 400。
            var reasoningContent: String? = nil

            enum CodingKeys: String, CodingKey {
                case role, content
                case toolCalls = "tool_calls"
                case toolCallID = "tool_call_id"
                case reasoningContent = "reasoning_content"
            }
        }

        struct OutgoingCall: Encodable {
            struct Function: Encodable {
                let name: String
                let arguments: String
            }

            let id: String
            let type = "function"
            let function: Function
        }

        /// 没有图片时 content 是字符串（兼容性最好）；有图片时是内容块数组。
        enum Content: Encodable {
            case text(String)
            case parts([Part])

            func encode(to encoder: any Encoder) throws {
                var container = encoder.singleValueContainer()
                switch self {
                case let .text(text): try container.encode(text)
                case let .parts(parts): try container.encode(parts)
                }
            }
        }

        struct Part: Encodable {
            struct ImageURL: Encodable {
                let url: String
            }

            let type: String
            let text: String?
            let imageURL: ImageURL?

            enum CodingKeys: String, CodingKey {
                case type, text
                case imageURL = "image_url"
            }
        }

        let model: String
        let messages: [Message]
        let stream: Bool
        let streamOptions: StreamOptions
        let reasoningEffort: String?
        /// DeepSeek 的服务端搜索工具，或者 App 的函数工具。
        let tools: [Tool]?
        /// OpenAI search 系列模型的联网搜索，内容是空对象。
        let webSearchOptions: EmptyObject?

        struct StreamOptions: Encodable {
            /// 让服务商在最后一个片段里返回用量。
            let includeUsage = true

            enum CodingKeys: String, CodingKey {
                case includeUsage = "include_usage"
            }
        }

        enum Tool: Encodable {
            /// 服务端执行的工具，只有 type，例如 deepseek_web_search。
            case server(String)
            case function(ToolDefinition)

            private enum CodingKeys: String, CodingKey { case type, function }
            private enum FunctionKeys: String, CodingKey { case name, description, parameters }

            func encode(to encoder: any Encoder) throws {
                var container = encoder.container(keyedBy: CodingKeys.self)
                switch self {
                case let .server(type):
                    try container.encode(type, forKey: .type)
                case let .function(tool):
                    try container.encode("function", forKey: .type)
                    var function = container.nestedContainer(keyedBy: FunctionKeys.self, forKey: .function)
                    try function.encode(tool.name, forKey: .name)
                    try function.encode(tool.description, forKey: .description)
                    try function.encode(tool.parameters, forKey: .parameters)
                }
            }
        }

        struct EmptyObject: Encodable {}

        enum CodingKeys: String, CodingKey {
            case model, messages, stream, tools
            case streamOptions = "stream_options"
            case reasoningEffort = "reasoning_effort"
            case webSearchOptions = "web_search_options"
        }
    }

    private static func content(for message: ChatMessage) -> RequestBody.Content {
        guard !message.images.isEmpty else { return .text(message.text) }
        var parts = message.images.map { data in
            RequestBody.Part(
                type: "image_url",
                text: nil,
                imageURL: .init(url: "data:image/jpeg;base64," + data.base64EncodedString())
            )
        }
        if !message.text.isEmpty {
            parts.append(.init(type: "text", text: message.text, imageURL: nil))
        }
        return .parts(parts)
    }

    public func makeURLRequest(for request: ChatRequest) throws -> URLRequest {
        var messages: [RequestBody.Message] = []
        if let system = request.trimmedSystemPrompt {
            messages.append(.init(role: "system", content: .text(system)))
        }
        for message in request.messages {
            // 工具结果每个调用一条 tool 消息；同一条里还有文字或图片时，再跟一条 user 消息。
            for result in message.toolResults {
                messages.append(.init(role: "tool", content: .text(result.content), toolCallID: result.callID))
            }
            if !message.toolResults.isEmpty, message.text.isEmpty, message.images.isEmpty { continue }
            var item = RequestBody.Message(role: message.role.rawValue, content: Self.content(for: message))
            if message.role == .assistant {
                if !message.toolCalls.isEmpty {
                    item.toolCalls = message.toolCalls.map {
                        .init(id: $0.id, function: .init(name: $0.name, arguments: $0.arguments.isEmpty ? "{}" : $0.arguments))
                    }
                }
                let reasoning = message.thinking.map(\.text).joined()
                if !reasoning.isEmpty { item.reasoningContent = reasoning }
            }
            messages.append(item)
        }

        var tools: [RequestBody.Tool] = []
        // DeepSeek 声明了搜索工具时不能再带 web_search_options，否则返回 400。
        if request.webSearch && request.webSearchDialect == .deepSeek { tools.append(.server("deepseek_web_search")) }
        tools += request.tools.map { .function($0) }

        var urlRequest = URLRequest(url: baseURL.appending(path: "chat/completions"))
        urlRequest.httpMethod = "POST"
        urlRequest.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        urlRequest.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        urlRequest.httpBody = try JSONEncoder().encode(RequestBody(
            model: request.model,
            messages: messages,
            stream: true,
            streamOptions: .init(),
            reasoningEffort: request.reasoningEffort?.rawValue,
            tools: tools.isEmpty ? nil : tools,
            webSearchOptions: request.webSearch && request.webSearchDialect == .openAI ? RequestBody.EmptyObject() : nil
        ))
        return urlRequest
    }

    // MARK: - 响应解析

    private struct StreamChunk: Decodable {
        struct Choice: Decodable {
            let delta: Delta?
            /// DeepSeek 联网搜索的进度（扩展字段）。
            let serverToolEvent: Lenient<ServerToolEvent>?
            let finishReason: String?

            enum CodingKeys: String, CodingKey {
                case delta
                case serverToolEvent = "server_tool_event"
                case finishReason = "finish_reason"
            }
        }

        struct Delta: Decodable {
            let content: String?
            /// DeepSeek 等服务商的思考过程字段。
            let reasoningContent: String?
            /// OpenRouter 的思考过程字段。
            let reasoning: String?
            /// 引用（OpenAI 和 DeepSeek 都用 url_citation），在最后一个片段里一次给出。
            let annotations: Lenient<[Annotation]>?
            /// 工具调用分几段给出：第一段有 id 和名字，后面按 index 接着给参数的片段。
            let toolCalls: Lenient<[ToolCallDelta]>?

            enum CodingKeys: String, CodingKey {
                case content, annotations
                case reasoningContent = "reasoning_content"
                case reasoning
                case toolCalls = "tool_calls"
            }
        }

        struct ToolCallDelta: Decodable {
            struct Function: Decodable {
                let name: String?
                let arguments: String?
            }

            let index: Int?
            let id: String?
            let function: Function?
        }

        struct Annotation: Decodable {
            struct URLCitation: Decodable {
                let url: String?
                let title: String?
                /// 按 Unicode 字符计的位置。
                let endIndex: Int?

                enum CodingKeys: String, CodingKey {
                    case url, title
                    case endIndex = "end_index"
                }
            }

            let type: String?
            let urlCitation: URLCitation?

            enum CodingKeys: String, CodingKey {
                case type
                case urlCitation = "url_citation"
            }
        }

        struct ServerToolEvent: Decodable {
            struct Call: Decodable {
                struct Action: Decodable {
                    let type: String?
                    let queries: [String]?
                }

                struct Source: Decodable {
                    let url: String?
                    let title: String?
                }

                let action: Action?
                let sources: [Source]?
            }

            let type: String?
            let call: Call?
        }

        struct Usage: Decodable {
            struct ServerToolUse: Decodable {
                let toolSearch: Int?

                enum CodingKeys: String, CodingKey {
                    case toolSearch = "tool_search"
                }
            }

            struct PromptDetails: Decodable {
                let cachedTokens: Int?
                enum CodingKeys: String, CodingKey { case cachedTokens = "cached_tokens" }
            }

            let promptTokens: Int?
            let completionTokens: Int?
            let totalTokens: Int?
            let serverToolUse: ServerToolUse?
            /// DeepSeek 的缓存命中数。
            let promptCacheHitTokens: Int?
            /// OpenAI 和多数兼容服务商的缓存命中数。
            let promptTokensDetails: PromptDetails?

            var cachedTokens: Int? { promptCacheHitTokens ?? promptTokensDetails?.cachedTokens }

            enum CodingKeys: String, CodingKey {
                case promptTokens = "prompt_tokens"
                case completionTokens = "completion_tokens"
                case totalTokens = "total_tokens"
                case serverToolUse = "server_tool_use"
                case promptCacheHitTokens = "prompt_cache_hit_tokens"
                case promptTokensDetails = "prompt_tokens_details"
            }

            /// 输出数。有的服务商（例如 grok）的 completion_tokens 不含思考过程，只算进了 total_tokens，
            /// 这时用 total - prompt。
            var output: Int? {
                guard let completion = completionTokens else { return nil }
                if let total = totalTokens, let prompt = promptTokens, total > prompt + completion {
                    return total - prompt
                }
                return completion
            }
        }

        let choices: [Choice]?
        let usage: Usage?
    }

    /// 解析一个 SSE 事件的 data 字段（不跨事件记状态；分几段给出的工具调用要用 `StreamDecoder`）。
    public static func decodeStreamData(_ data: String) throws -> StreamPayload {
        let decoder = StreamDecoder()
        let payload = try decoder.decode(data)
        guard case let .events(events) = payload else { return payload }
        return .events(events + decoder.finish())
    }

    /// 一次流式回答的解析器：把分几段给出的工具调用拼完整，在 finish_reason 或流结束时发出。
    /// 只在一个流里按顺序使用。
    public final class StreamDecoder: @unchecked Sendable {
        private struct PendingCall {
            var id = ""
            var name = ""
            var arguments = ""
        }

        /// 按 index 收集的工具调用；没有 index 的服务商按出现顺序编号。
        private var pending: [Int: PendingCall] = [:]
        private var order: [Int] = []

        public init() {}

        public func decode(_ data: String) throws -> StreamPayload {
            let trimmed = data.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed == "[DONE]" {
                return .done
            }

            let bytes = Data(trimmed.utf8)
            if let message = APIErrorMessage.extract(from: bytes) {
                throw ChatServiceError.server(message: message)
            }

            let chunk: StreamChunk
            do {
                chunk = try JSONDecoder().decode(StreamChunk.self, from: bytes)
            } catch {
                throw ChatServiceError.invalidResponse
            }

            var events = OpenAICompatibleService.events(from: chunk)
            for delta in chunk.choices?.first?.delta?.toolCalls?.value ?? [] {
                let index = delta.index ?? (delta.id != nil ? order.count : max(order.count - 1, 0))
                if pending[index] == nil {
                    pending[index] = PendingCall()
                    order.append(index)
                }
                if let id = delta.id, !id.isEmpty { pending[index]?.id = id }
                // 名字只在第一段给出；有的服务商每段都重复一次，所以只取第一次。
                if let name = delta.function?.name, !name.isEmpty, pending[index]?.name.isEmpty == true {
                    pending[index]?.name = name
                }
                pending[index]?.arguments += delta.function?.arguments ?? ""
            }
            if chunk.choices?.first?.finishReason != nil {
                events += finish()
            }
            return .events(events)
        }

        /// 发出收完整的工具调用。流结束时调用一次。
        public func finish() -> [ChatStreamEvent] {
            let calls = order.compactMap { pending[$0] }.enumerated().compactMap { offset, call -> ChatStreamEvent? in
                guard !call.name.isEmpty else { return nil }
                let id = call.id.isEmpty ? ToolCall.localIDPrefix + "\(offset)" : call.id
                return .toolCall(ToolCall(id: id, name: call.name, arguments: call.arguments))
            }
            pending = [:]
            order = []
            return calls
        }
    }

    private static func events(from chunk: StreamChunk) -> [ChatStreamEvent] {
        var events: [ChatStreamEvent] = []
        if let toolEvent = chunk.choices?.first?.serverToolEvent?.value {
            events += searchEvents(from: toolEvent)
        }
        if let delta = chunk.choices?.first?.delta {
            if let reasoning = delta.reasoningContent ?? delta.reasoning, !reasoning.isEmpty {
                events.append(.reasoning(reasoning))
            }
            if let content = delta.content, !content.isEmpty {
                events.append(.text(content))
            }
            let citations = (delta.annotations?.value ?? []).compactMap { annotation -> Citation? in
                guard annotation.type == nil || annotation.type == "url_citation",
                      let info = annotation.urlCitation, let url = info.url, !url.isEmpty, let end = info.endIndex
                else { return nil }
                return Citation(sources: [WebSource(url: url, title: info.title ?? "")], anchor: .offset(end))
            }
            if !citations.isEmpty {
                events.append(.citations(citations))
            }
        }
        if let usage = chunk.usage, usage.promptTokens != nil || usage.completionTokens != nil {
            events.append(.usage(input: usage.promptTokens, output: usage.output))
            if let cached = usage.cachedTokens, cached > 0 { events.append(.cachedInput(cached)) }
        }
        if let searches = chunk.usage?.serverToolUse?.toolSearch, searches > 0 {
            events.append(.searchCount(searches))
        }
        return events
    }

    /// DeepSeek 的搜索进度：开始搜索时给出搜索词，搜完给出结果。打开网页、读链接不算搜索。
    private static func searchEvents(from event: StreamChunk.ServerToolEvent) -> [ChatStreamEvent] {
        guard let call = event.call else { return [] }
        switch event.type {
        case "call_started":
            guard call.action?.type == "search" else { return [] }
            let query = (call.action?.queries ?? []).filter { !$0.isEmpty }.joined(separator: " / ")
            return [.searching(query: query.isEmpty ? nil : query)]
        case "call_completed":
            let sources = (call.sources ?? []).compactMap { source -> WebSource? in
                guard let url = source.url, !url.isEmpty else { return nil }
                return WebSource(url: url, title: source.title ?? "")
            }
            return sources.isEmpty ? [] : [.searchResults(sources)]
        default:
            return []
        }
    }

    // MARK: - 流式请求

    public func streamChat(_ request: ChatRequest) -> AsyncThrowingStream<ChatStreamEvent, any Error> {
        do {
            let decoder = StreamDecoder()
            return SSEStreaming.stream(
                session: session,
                request: try makeURLRequest(for: request),
                decode: { try decoder.decode($0.data) },
                finish: { decoder.finish() }
            )
        } catch {
            return AsyncThrowingStream { $0.finish(throwing: error) }
        }
    }
}
