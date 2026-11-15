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
        let text: String?
        let thought: Bool?

        init(text: String) {
            self.text = text
            self.thought = nil
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
            contents: request.alternatingMessages.map {
                Content(role: $0.role == .user ? "user" : "model", parts: [Part(text: $0.text)])
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

        let candidates: [Candidate]?
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
        let events: [ChatStreamEvent] = parts.compactMap { part in
            guard let text = part.text, !text.isEmpty else { return nil }
            return part.thought == true ? .reasoning(text) : .text(text)
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
