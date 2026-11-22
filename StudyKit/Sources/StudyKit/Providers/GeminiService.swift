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

        /// Google 搜索接地。内容是空对象。
        struct Tool: Encodable {
            struct GoogleSearch: Encodable {}
            let googleSearch = GoogleSearch()

            enum CodingKeys: String, CodingKey {
                case googleSearch = "google_search"
            }
        }

        let contents: [Content]
        let systemInstruction: Content?
        let generationConfig: GenerationConfig
        let tools: [Tool]?
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
            )),
            tools: request.webSearch ? [RequestBody.Tool()] : nil
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
            let groundingMetadata: Lenient<GroundingMetadata>?
        }

        /// 联网搜索的结果：搜索词、用到的网页、正文里哪段话依据哪些网页。每个片段给的都是累计值。
        struct GroundingMetadata: Decodable {
            struct Chunk: Decodable {
                struct Web: Decodable {
                    let uri: String?
                    let title: String?
                }

                let web: Web?
            }

            struct Support: Decodable {
                struct Segment: Decodable {
                    let text: String?
                }

                let segment: Segment?
                let groundingChunkIndices: [Int]?
            }

            let webSearchQueries: [String]?
            let groundingChunks: [Chunk]?
            let groundingSupports: [Support]?
        }

        struct UsageMetadata: Decodable {
            let promptTokenCount: Int?
            let candidatesTokenCount: Int?
            let thoughtsTokenCount: Int?
            let cachedContentTokenCount: Int?
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
            if let cached = usage.cachedContentTokenCount, cached > 0 { events.append(.cachedInput(cached)) }
        }
        if let grounding = chunk.candidates?.first?.groundingMetadata?.value {
            events += groundingEvents(grounding)
        }
        return .events(events)
    }

    /// 接地信息转成搜索事件。Gemini 3 起按搜索词计费，搜索次数就是搜索词的个数。
    private static func groundingEvents(_ grounding: StreamChunk.GroundingMetadata) -> [ChatStreamEvent] {
        var events: [ChatStreamEvent] = []
        let queries = (grounding.webSearchQueries ?? []).filter { !$0.isEmpty }
        events += queries.map { .searching(query: $0) }
        let sources: [WebSource?] = (grounding.groundingChunks ?? []).map { chunk in
            guard let uri = chunk.web?.uri, !uri.isEmpty else { return nil }
            return WebSource(url: uri, title: chunk.web?.title ?? "")
        }
        let found = sources.compactMap { $0 }
        if !found.isEmpty {
            events.append(.searchResults(found))
        }
        let citations = (grounding.groundingSupports ?? []).compactMap { support -> Citation? in
            guard let text = support.segment?.text, !text.isEmpty else { return nil }
            let cited = (support.groundingChunkIndices ?? []).compactMap { index -> WebSource? in
                sources.indices.contains(index) ? sources[index] : nil
            }
            return cited.isEmpty ? nil : Citation(sources: cited, anchor: .afterText(text))
        }
        if !citations.isEmpty {
            events.append(.citations(citations))
        }
        if !queries.isEmpty {
            events.append(.searchCount(queries.count))
        }
        return events
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
