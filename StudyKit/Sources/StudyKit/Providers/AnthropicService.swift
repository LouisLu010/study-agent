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

        struct Block: Encodable {
            struct Source: Encodable {
                let type = "base64"
                let mediaType = "image/jpeg"
                let data: String

                enum CodingKeys: String, CodingKey {
                    case type, data
                    case mediaType = "media_type"
                }
            }

            let type: String
            let text: String?
            let source: Source?
        }

        struct Thinking: Encodable {
            let type = "adaptive"
            /// 新模型默认不返回思考内容，要显式要求返回摘要。
            let display = "summarized"
        }

        struct OutputConfig: Encodable {
            let effort: String
        }

        /// 服务端执行的联网搜索工具。用最早的版本号，MiniMax、DeepSeek 的 Anthropic 接口也认识。
        struct WebSearchTool: Encodable {
            let type = "web_search_20250305"
            let name = "web_search"
            let maxUses = AnthropicService.maxWebSearches

            enum CodingKeys: String, CodingKey {
                case type, name
                case maxUses = "max_uses"
            }
        }

        let model: String
        let maxTokens: Int
        let system: String?
        let messages: [Message]
        let stream: Bool
        let thinking: Thinking?
        let outputConfig: OutputConfig?
        let tools: [WebSearchTool]?

        enum CodingKeys: String, CodingKey {
            case model, system, messages, stream, thinking, tools
            case maxTokens = "max_tokens"
            case outputConfig = "output_config"
        }
    }

    /// 一次回答最多搜索几次，控制费用。
    static let maxWebSearches = 5

    public func makeURLRequest(for request: ChatRequest) throws -> URLRequest {
        // 只在用户设置了思考强度时才打开思考，避免不支持的旧模型报错。
        let effort = request.reasoningEffort
        let body = RequestBody(
            model: request.model,
            maxTokens: Self.maxTokens,
            system: request.trimmedSystemPrompt,
            messages: request.alternatingMessages.map { message in
                // 图片放在文字前面；Anthropic 不接受空的文字块。
                var blocks = message.images.map {
                    RequestBody.Block(type: "image", text: nil, source: .init(data: $0.base64EncodedString()))
                }
                if !message.text.isEmpty || blocks.isEmpty {
                    blocks.append(.init(type: "text", text: message.text, source: nil))
                }
                return .init(role: message.role.rawValue, content: blocks)
            },
            stream: true,
            thinking: effort == nil ? nil : RequestBody.Thinking(),
            outputConfig: effort.map { RequestBody.OutputConfig(effort: $0.rawValue) },
            tools: request.webSearch ? [RequestBody.WebSearchTool()] : nil
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
            let partialJSON: String?
            let citation: CitationInfo?

            enum CodingKeys: String, CodingKey {
                case type, text, thinking, citation
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
            let name: String?
            let input: ToolInput?
            let content: Results?
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
                        return .events([.reasoning(thinking)])
                    }
                case "input_json_delta":
                    if let index = event.index, toolInputs[index] != nil {
                        toolInputs[index, default: ""] += event.delta?.partialJSON ?? ""
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
                    return .events([.usage(input: input, output: nil)])
                }
                return .events([])
            case "message_delta":
                // output_tokens 和搜索次数都是累计值。
                var events: [ChatStreamEvent] = []
                if let usage = event.usage, usage.outputTokens != nil || usage.totalInput != nil {
                    events.append(.usage(input: usage.totalInput, output: usage.outputTokens))
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
            default:
                return []
            }
        }

        private func blockStop(index: Int?) -> [ChatStreamEvent] {
            guard let index else { return [] }
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
