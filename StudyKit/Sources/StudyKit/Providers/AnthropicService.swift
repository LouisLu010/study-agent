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
            let content: String
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

        enum CodingKeys: String, CodingKey {
            case model, system, messages, stream, thinking
            case maxTokens = "max_tokens"
            case outputConfig = "output_config"
        }
    }

    public func makeURLRequest(for request: ChatRequest) throws -> URLRequest {
        // 只在用户设置了思考强度时才打开思考，避免不支持的旧模型报错。
        let effort = request.reasoningEffort
        let body = RequestBody(
            model: request.model,
            maxTokens: Self.maxTokens,
            system: request.trimmedSystemPrompt,
            messages: request.alternatingMessages.map { .init(role: $0.role.rawValue, content: $0.text) },
            stream: true,
            thinking: effort == nil ? nil : RequestBody.Thinking(),
            outputConfig: effort.map { RequestBody.OutputConfig(effort: $0.rawValue) }
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

    private struct StreamEvent: Decodable {
        struct Delta: Decodable {
            let type: String?
            let text: String?
            let thinking: String?
        }

        struct APIError: Decodable {
            let message: String?
        }

        let type: String
        let delta: Delta?
        let error: APIError?
    }

    public static func decodeStreamData(_ data: String) throws -> StreamPayload {
        let event: StreamEvent
        do {
            event = try JSONDecoder().decode(StreamEvent.self, from: Data(data.utf8))
        } catch {
            throw ChatServiceError.invalidResponse
        }

        switch event.type {
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
            default:
                break
            }
            return .events([])
        case "message_stop":
            return .done
        case "error":
            throw ChatServiceError.server(message: event.error?.message ?? "未知错误")
        default:
            return .events([])
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
