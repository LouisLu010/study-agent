import Foundation

/// Google Gemini streamGenerateContent 接口（SSE 模式）。
/// https://ai.google.dev/gemini-api/docs/text-generation
public struct GeminiService: ChatService {
    public let baseURL: URL
    public let apiKey: String
    private let session: URLSession

    public init(baseURL: URL, apiKey: String, session: URLSession = .shared) {
        self.baseURL = baseURL
        self.apiKey = apiKey
        self.session = session
    }

    // MARK: - 请求

    private struct Part: Codable {
        struct InlineData: Codable {
            let mimeType: String
            let data: String
        }

        let text: String?
        let thought: Bool?
        let inlineData: InlineData?

        init(text: String) {
            self.text = text
            self.thought = nil
            self.inlineData = nil
        }

        init(jpeg: Data) {
            self.text = nil
            self.thought = nil
            self.inlineData = InlineData(mimeType: "image/jpeg", data: jpeg.base64EncodedString())
        }
    }

    private struct Content: Encodable {
        let role: String?
        let parts: [Part]
    }

    private struct RequestBody: Encodable {
        struct GenerationConfig: Encodable {
            let thinkingConfig: ThinkingConfig
        }

        struct ThinkingConfig: Encodable {
            let includeThoughts: Bool
            let thinkingLevel: String?
        }

        let contents: [Content]
        let systemInstruction: Content?
        let generationConfig: GenerationConfig
    }

    public func makeURLRequest(for request: ChatRequest) throws -> URLRequest {
        let model = request.model.hasPrefix("models/") ? String(request.model.dropFirst(7)) : request.model
        let url = baseURL
            .appending(path: "models/\(model):streamGenerateContent")
            .appending(queryItems: [URLQueryItem(name: "alt", value: "sse")])

        let body = RequestBody(
            contents: request.alternatingMessages.map { message in
                var parts = message.images.map { Part(jpeg: $0) }
                if !message.text.isEmpty || parts.isEmpty {
                    parts.append(Part(text: message.text))
                }
                return Content(role: message.role == .user ? "user" : "model", parts: parts)
            },
            systemInstruction: request.trimmedSystemPrompt.map { Content(role: nil, parts: [Part(text: $0)]) },
            generationConfig: .init(thinkingConfig: .init(
                includeThoughts: true,
                thinkingLevel: request.reasoningEffort?.rawValue
            ))
        )

        var urlRequest = URLRequest(url: url)
        urlRequest.httpMethod = "POST"
        urlRequest.setValue(apiKey, forHTTPHeaderField: "x-goog-api-key")
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        urlRequest.httpBody = try JSONEncoder().encode(body)
        return urlRequest
    }

    // MARK: - 响应解析

    private struct StreamChunk: Decodable {
        struct Candidate: Decodable {
            struct CandidateContent: Decodable {
                let parts: [Part]?
            }

            let content: CandidateContent?
        }

        struct UsageMetadata: Decodable {
            let promptTokenCount: Int?
            let candidatesTokenCount: Int?
            let thoughtsTokenCount: Int?
        }

        let candidates: [Candidate]?
        let usageMetadata: UsageMetadata?
    }

    public static func decodeStreamData(_ data: String) throws -> StreamPayload {
        let bytes = Data(data.utf8)
        if let message = APIErrorMessage.extract(from: bytes) {
            throw ChatServiceError.server(message: message)
        }

        let chunk: StreamChunk
        do {
            chunk = try JSONDecoder().decode(StreamChunk.self, from: bytes)
        } catch {
            throw ChatServiceError.invalidResponse
        }

        let parts = chunk.candidates?.first?.content?.parts ?? []
        var events: [ChatStreamEvent] = parts.compactMap { part in
            guard let text = part.text, !text.isEmpty else { return nil }
            return part.thought == true ? .reasoning(text) : .text(text)
        }
        // 每个片段都带着到目前为止的累计用量；输出包括思考过程。
        if let usage = chunk.usageMetadata, usage.promptTokenCount != nil || usage.candidatesTokenCount != nil {
            let output = usage.candidatesTokenCount.map { $0 + (usage.thoughtsTokenCount ?? 0) }
                ?? usage.thoughtsTokenCount
            events.append(.usage(input: usage.promptTokenCount, output: output))
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
