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
        /// DeepSeek 的服务端搜索工具。
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

        struct Tool: Encodable {
            let type: String
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
        messages += request.messages.map { .init(role: $0.role.rawValue, content: Self.content(for: $0)) }

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
            // DeepSeek 声明了搜索工具时不能再带 web_search_options，否则返回 400。
            tools: request.webSearch && request.webSearchDialect == .deepSeek
                ? [RequestBody.Tool(type: "deepseek_web_search")] : nil,
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

            enum CodingKeys: String, CodingKey {
                case delta
                case serverToolEvent = "server_tool_event"
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

            enum CodingKeys: String, CodingKey {
                case content, annotations
                case reasoningContent = "reasoning_content"
                case reasoning
            }
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

            let promptTokens: Int?
            let completionTokens: Int?
            let totalTokens: Int?
            let serverToolUse: ServerToolUse?

            enum CodingKeys: String, CodingKey {
                case promptTokens = "prompt_tokens"
                case completionTokens = "completion_tokens"
                case totalTokens = "total_tokens"
                case serverToolUse = "server_tool_use"
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

    /// 解析一个 SSE 事件的 data 字段。
    public static func decodeStreamData(_ data: String) throws -> StreamPayload {
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
        }
        if let searches = chunk.usage?.serverToolUse?.toolSearch, searches > 0 {
            events.append(.searchCount(searches))
        }
        return .events(events)
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
            return SSEStreaming.stream(session: session, request: try makeURLRequest(for: request)) { event in
                try Self.decodeStreamData(event.data)
            }
        } catch {
            return AsyncThrowingStream { $0.finish(throwing: error) }
        }
    }
}
