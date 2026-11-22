import Foundation

/// Anthropic Messages 流式接口（Claude）。
/// https://platform.claude.com/docs/en/build-with-claude/streaming
public struct AnthropicService: ChatService {
    public let baseURL: URL
    public let apiKey: String
    private let session: URLSession

    /// Messages API 要求必须设置 max_tokens，思考过程也计入其中。
    static let maxTokens = 16000
    static let apiVersion = "2023-06-01"

    public init(baseURL: URL, apiKey: String, session: URLSession = .shared) {
        self.baseURL = baseURL
        self.apiKey = apiKey
        self.session = session
    }

    // MARK: - 请求

    private struct RequestBody: Encodable {
        struct Message: Encodable {
            let role: String
            let content: [Block]
        }

        enum Block: Encodable {
            case text(String)
            /// JPEG 的 base64。
            case image(String)
            case thinking(text: String, signature: String)
            case redactedThinking(String)
            case toolUse(id: String, name: String, input: JSONValue)
            case toolResult(id: String, content: String)

            private enum CodingKeys: String, CodingKey {
                case type, text, source, thinking, signature, data, id, name, input, content
                case toolUseID = "tool_use_id"
            }

            private enum SourceKeys: String, CodingKey {
                case type, data
                case mediaType = "media_type"
            }

            func encode(to encoder: any Encoder) throws {
                var container = encoder.container(keyedBy: CodingKeys.self)
                switch self {
                case let .text(text):
                    try container.encode("text", forKey: .type)
                    try container.encode(text, forKey: .text)
                case let .image(data):
                    try container.encode("image", forKey: .type)
                    var source = container.nestedContainer(keyedBy: SourceKeys.self, forKey: .source)
                    try source.encode("base64", forKey: .type)
                    try source.encode("image/jpeg", forKey: .mediaType)
                    try source.encode(data, forKey: .data)
                case let .thinking(text, signature):
                    try container.encode("thinking", forKey: .type)
                    try container.encode(text, forKey: .thinking)
                    try container.encode(signature, forKey: .signature)
                case let .redactedThinking(data):
                    try container.encode("redacted_thinking", forKey: .type)
                    try container.encode(data, forKey: .data)
                case let .toolUse(id, name, input):
                    try container.encode("tool_use", forKey: .type)
                    try container.encode(id, forKey: .id)
                    try container.encode(name, forKey: .name)
                    try container.encode(input, forKey: .input)
                case let .toolResult(id, content):
                    try container.encode("tool_result", forKey: .type)
                    try container.encode(id, forKey: .toolUseID)
                    try container.encode(content, forKey: .content)
                }
            }
        }

        enum Tool: Encodable {
            case webSearch
            case custom(ToolDefinition)

            private enum CodingKeys: String, CodingKey {
                case type, name, description
                case maxUses = "max_uses"
                case inputSchema = "input_schema"
            }

            func encode(to encoder: any Encoder) throws {
                var container = encoder.container(keyedBy: CodingKeys.self)
                switch self {
                case .webSearch:
                    // 服务端执行的联网搜索。用最早的版本号，MiniMax、DeepSeek 的 Anthropic 接口也认识。
                    try container.encode("web_search_20250305", forKey: .type)
                    try container.encode("web_search", forKey: .name)
                    try container.encode(AnthropicService.maxWebSearches, forKey: .maxUses)
                case let .custom(tool):
                    try container.encode(tool.name, forKey: .name)
                    try container.encode(tool.description, forKey: .description)
                    try container.encode(tool.parameters, forKey: .inputSchema)
                }
            }
        }

        struct Thinking: Encodable {
            let type = "adaptive"
            /// 新模型默认不返回思考内容，要显式要求返回摘要。
            let display = "summarized"
        }

        struct OutputConfig: Encodable {
            let effort: String
        }

        let model: String
        let maxTokens: Int
        let system: String?
        let messages: [Message]
        let stream: Bool
        let thinking: Thinking?
        let outputConfig: OutputConfig?
        let tools: [Tool]?

        enum CodingKeys: String, CodingKey {
            case model, system, messages, stream, thinking, tools
            case maxTokens = "max_tokens"
            case outputConfig = "output_config"
        }
    }

    /// 一次回答最多搜索几次，控制费用。
    static let maxWebSearches = 5

    /// 一条消息的内容块。user：工具结果在最前面（Anthropic 要求），然后是图片、文字。
    /// assistant：思考块在最前面（打开思考时调用工具必须原样传回），然后是文字、工具调用。
    /// Anthropic 不接受空的文字块。
    private static func blocks(for message: ChatMessage) -> [RequestBody.Block] {
        var blocks: [RequestBody.Block] = message.toolResults.map { .toolResult(id: $0.callID, content: $0.content) }
        if message.role == .assistant {
            for thinking in message.thinking {
                if let data = thinking.redactedData {
                    blocks.append(.redactedThinking(data))
                } else if let signature = thinking.signature {
                    blocks.append(.thinking(text: thinking.text, signature: signature))
                }
            }
        }
        blocks += message.images.map { .image($0.base64EncodedString()) }
        if !message.text.isEmpty || (blocks.isEmpty && message.toolCalls.isEmpty) {
            blocks.append(.text(message.text))
        }
        blocks += message.toolCalls.map { .toolUse(id: $0.id, name: $0.name, input: $0.input) }
        return blocks
    }

    public func makeURLRequest(for request: ChatRequest) throws -> URLRequest {
        // 只在用户设置了思考强度时才打开思考，避免不支持的旧模型报错。
        let effort = request.reasoningEffort
        let tools: [RequestBody.Tool] = (request.webSearch ? [.webSearch] : []) + request.tools.map { .custom($0) }
        let body = RequestBody(
            model: request.model,
            maxTokens: Self.maxTokens,
            system: request.trimmedSystemPrompt,
            messages: request.alternatingMessages.map { message in
                .init(role: message.role.rawValue, content: Self.blocks(for: message))
            },
            stream: true,
            thinking: effort == nil ? nil : RequestBody.Thinking(),
            outputConfig: effort.map { RequestBody.OutputConfig(effort: $0.rawValue) },
            tools: tools.isEmpty ? nil : tools
        )

        var urlRequest = URLRequest(url: baseURL.appending(path: "messages"))
        urlRequest.httpMethod = "POST"
        urlRequest.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        urlRequest.setValue(Self.apiVersion, forHTTPHeaderField: "anthropic-version")
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        urlRequest.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        urlRequest.httpBody = try JSONEncoder().encode(body)
        return urlRequest
    }

    // MARK: - 响应解析

    fileprivate struct StreamEvent: Decodable {
        struct Delta: Decodable {
            struct CitationInfo: Decodable {
                let url: String?
                let title: String?
            }

            let type: String?
            let text: String?
            let thinking: String?
            let signature: String?
            let partialJSON: String?
            let citation: CitationInfo?

            enum CodingKeys: String, CodingKey {
                case type, text, thinking, citation, signature
                case partialJSON = "partial_json"
            }
        }

        struct APIError: Decodable {
            let message: String?
        }

        struct Usage: Decodable {
            struct ServerToolUse: Decodable {
                let webSearchRequests: Int?

                enum CodingKeys: String, CodingKey {
                    case webSearchRequests = "web_search_requests"
                }
            }

            let inputTokens: Int?
            let outputTokens: Int?
            let cacheCreationInputTokens: Int?
            let cacheReadInputTokens: Int?
            let serverToolUse: ServerToolUse?

            enum CodingKeys: String, CodingKey {
                case inputTokens = "input_tokens"
                case outputTokens = "output_tokens"
                case cacheCreationInputTokens = "cache_creation_input_tokens"
                case cacheReadInputTokens = "cache_read_input_tokens"
                case serverToolUse = "server_tool_use"
            }

            /// 输入总数：普通输入加上缓存写入和缓存命中的部分。
            var totalInput: Int? {
                guard inputTokens != nil || cacheCreationInputTokens != nil || cacheReadInputTokens != nil else { return nil }
                return (inputTokens ?? 0) + (cacheCreationInputTokens ?? 0) + (cacheReadInputTokens ?? 0)
            }
        }

        struct MessageInfo: Decodable {
            let usage: Usage?
        }

        /// 内容块开始时的信息。联网搜索时有 server_tool_use（搜索词）和 web_search_tool_result（结果）两种块。
        struct ContentBlock: Decodable {
            struct ToolInput: Decodable {
                let query: String?
                /// DeepSeek 的 Anthropic 接口用 queries 数组。
                let queries: [String]?

                enum CodingKeys: String, CodingKey { case query, queries }

                init(from decoder: any Decoder) throws {
                    let container = try? decoder.container(keyedBy: CodingKeys.self)
                    query = try? container?.decodeIfPresent(String.self, forKey: .query)
                    queries = try? container?.decodeIfPresent([String].self, forKey: .queries)
                }

                var text: String? {
                    if let query, !query.isEmpty { return query }
                    if let queries, !queries.isEmpty { return queries.joined(separator: " / ") }
                    return nil
                }
            }

            struct WebResult: Decodable {
                let url: String?
                let title: String?
            }

            /// 搜索结果是数组；出错时是一个对象，这时当作没有结果。
            struct Results: Decodable {
                let items: [WebResult]

                init(from decoder: any Decoder) throws {
                    items = (try? decoder.singleValueContainer().decode([WebResult].self)) ?? []
                }
            }

            let type: String
            let id: String?
            let name: String?
            let input: ToolInput?
            let content: Results?
            /// redacted_thinking 块的内容。
            let data: String?
            /// thinking 块开始时可能已经带着文字和签名。
            let thinking: String?
            let signature: String?
        }

        let type: String
        let index: Int?
        let delta: Delta?
        let error: APIError?
        let message: MessageInfo?
        let usage: Usage?
        let contentBlock: ContentBlock?

        enum CodingKeys: String, CodingKey {
            case type, index, delta, error, message, usage
            case contentBlock = "content_block"
        }
    }

    /// 解析一个 SSE 事件的 data 字段（不跨事件记状态，联网搜索的搜索词和引用需要 `StreamDecoder`）。
    public static func decodeStreamData(_ data: String) throws -> StreamPayload {
        try StreamDecoder().decode(data)
    }

    /// 一次流式回答的解析器。联网搜索的搜索词分几段给出，引用要等文字块结束才能定位，所以要记状态。
    /// 只在一个流里按顺序使用。
    public final class StreamDecoder: @unchecked Sendable {
        /// 搜索工具块的序号 → 已收到的输入 JSON 片段。
        private var toolInputs: [Int: String] = [:]
        /// 文字块的序号 → 这个块里的引用。
        private var blockCitations: [Int: [WebSource]] = [:]
        /// App 工具调用块的序号 → ID、名字和已收到的参数 JSON 片段。
        private var toolUses: [Int: (id: String, name: String, json: String)] = [:]
        /// 思考块的序号 → 文字和签名。
        private var thinkingBlocks: [Int: ThinkingBlock] = [:]

        public init() {}

        public func decode(_ data: String) throws -> StreamPayload {
            let event: StreamEvent
            do {
                event = try JSONDecoder().decode(StreamEvent.self, from: Data(data.utf8))
            } catch {
                throw ChatServiceError.invalidResponse
            }

            switch event.type {
            case "content_block_start":
                return .events(blockStart(event))
            case "content_block_delta":
                switch event.delta?.type {
                case "text_delta":
                    if let text = event.delta?.text, !text.isEmpty {
                        return .events([.text(text)])
                    }
                case "thinking_delta":
                    if let thinking = event.delta?.thinking, !thinking.isEmpty {
                        if let index = event.index { thinkingBlocks[index]?.text += thinking }
                        return .events([.reasoning(thinking)])
                    }
                case "signature_delta":
                    if let index = event.index, let signature = event.delta?.signature, var block = thinkingBlocks[index] {
                        block.signature = (block.signature ?? "") + signature
                        thinkingBlocks[index] = block
                    }
                case "input_json_delta":
                    if let index = event.index, toolInputs[index] != nil {
                        toolInputs[index, default: ""] += event.delta?.partialJSON ?? ""
                    } else if let index = event.index, toolUses[index] != nil {
                        toolUses[index]?.json += event.delta?.partialJSON ?? ""
                    }
                case "citations_delta":
                    if let index = event.index, let citation = event.delta?.citation,
                       let url = citation.url, !url.isEmpty {
                        blockCitations[index, default: []].append(WebSource(url: url, title: citation.title ?? ""))
                    }
                default:
                    break
                }
                return .events([])
            case "content_block_stop":
                return .events(blockStop(index: event.index))
            case "message_start":
                // 开始时给出输入数；输出数这时还不准，等 message_delta。
                if let usage = event.message?.usage, let input = usage.totalInput {
                    var events: [ChatStreamEvent] = [.usage(input: input, output: nil)]
                    if let cached = usage.cacheReadInputTokens, cached > 0 { events.append(.cachedInput(cached)) }
                    return .events(events)
                }
                return .events([])
            case "message_delta":
                // output_tokens 和搜索次数都是累计值。
                var events: [ChatStreamEvent] = []
                if let usage = event.usage, usage.outputTokens != nil || usage.totalInput != nil {
                    events.append(.usage(input: usage.totalInput, output: usage.outputTokens))
                    if let cached = usage.cacheReadInputTokens, cached > 0 { events.append(.cachedInput(cached)) }
                }
                if let searches = event.usage?.serverToolUse?.webSearchRequests, searches > 0 {
                    events.append(.searchCount(searches))
                }
                return .events(events)
            case "message_stop":
                return .done
            case "error":
                throw ChatServiceError.server(message: event.error?.message ?? "未知错误")
            default:
                return .events([])
            }
        }

        private func blockStart(_ event: StreamEvent) -> [ChatStreamEvent] {
            guard let block = event.contentBlock else { return [] }
            switch block.type {
            case "server_tool_use":
                guard block.name == nil || block.name?.contains("search") == true else { return [] }
                // 搜索词通常在后面的 input_json_delta 里，块结束时再解析。
                if let index = event.index { toolInputs[index] = "" }
                return [.searching(query: block.input?.text)]
            case "web_search_tool_result":
                let sources = (block.content?.items ?? []).compactMap { result -> WebSource? in
                    guard let url = result.url, !url.isEmpty else { return nil }
                    return WebSource(url: url, title: result.title ?? "")
                }
                return sources.isEmpty ? [] : [.searchResults(sources)]
            case "tool_use":
                if let index = event.index, let name = block.name {
                    toolUses[index] = (block.id ?? ToolCall.localIDPrefix + "\(index)", name, "")
                }
                return []
            case "thinking":
                guard let index = event.index else { return [] }
                let text = block.thinking ?? ""
                thinkingBlocks[index] = ThinkingBlock(text: text, signature: block.signature)
                return text.isEmpty ? [] : [.reasoning(text)]
            case "redacted_thinking":
                guard let data = block.data else { return [] }
                return [.thinkingBlock(ThinkingBlock(text: "", redactedData: data))]
            default:
                return []
            }
        }

        private func blockStop(index: Int?) -> [ChatStreamEvent] {
            guard let index else { return [] }
            if let call = toolUses.removeValue(forKey: index) {
                let json = call.json.trimmingCharacters(in: .whitespacesAndNewlines)
                return [.toolCall(ToolCall(id: call.id, name: call.name, arguments: json.isEmpty ? "{}" : json))]
            }
            if let thinking = thinkingBlocks.removeValue(forKey: index) {
                return (thinking.signature ?? "").isEmpty ? [] : [.thinkingBlock(thinking)]
            }
            if let json = toolInputs.removeValue(forKey: index) {
                guard !json.isEmpty,
                      let input = try? JSONDecoder().decode(StreamEvent.ContentBlock.ToolInput.self, from: Data(json.utf8)),
                      let query = input.text
                else { return [] }
                return [.searching(query: query)]
            }
            if let sources = blockCitations.removeValue(forKey: index), !sources.isEmpty {
                return [.citations([Citation(sources: sources, anchor: .end)])]
            }
            return []
        }
    }

    // MARK: - 流式请求

    public func streamChat(_ request: ChatRequest) -> AsyncThrowingStream<ChatStreamEvent, any Error> {
        do {
            let decoder = StreamDecoder()
            return SSEStreaming.stream(session: session, request: try makeURLRequest(for: request)) { event in
                try decoder.decode(event.data)
            }
        } catch {
            return AsyncThrowingStream { $0.finish(throwing: error) }
        }
    }
}
