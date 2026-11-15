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
        let reasoningEffort: String?

        enum CodingKeys: String, CodingKey {
            case model, messages, stream
            case reasoningEffort = "reasoning_effort"
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
            reasoningEffort: request.reasoningEffort?.rawValue
        ))
        return urlRequest
    }

    // MARK: - 响应解析

    private struct StreamChunk: Decodable {
        struct Choice: Decodable {
            let delta: Delta?
        }

        struct Delta: Decodable {
            let content: String?
            /// DeepSeek 等服务商的思考过程字段。
            let reasoningContent: String?
            /// OpenRouter 的思考过程字段。
            let reasoning: String?

            enum CodingKeys: String, CodingKey {
                case content
                case reasoningContent = "reasoning_content"
                case reasoning
            }
        }

        let choices: [Choice]?
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
        if let delta = chunk.choices?.first?.delta {
            if let reasoning = delta.reasoningContent ?? delta.reasoning, !reasoning.isEmpty {
                events.append(.reasoning(reasoning))
            }
            if let content = delta.content, !content.isEmpty {
                events.append(.text(content))
            }
        }
        return .events(events)
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
