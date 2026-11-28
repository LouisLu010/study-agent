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

        struct FunctionCall: Codable {
            var id: String?
            let name: String
            var args: JSONValue?

            enum CodingKeys: String, CodingKey { case id, name, args }

            init(id: String?, name: String, args: JSONValue?) {
                self.id = id
                self.name = name
                self.args = args
            }

            init(from decoder: any Decoder) throws {
                let container = try decoder.container(keyedBy: CodingKeys.self)
                id = try container.decodeIfPresent(String.self, forKey: .id)
                name = try container.decode(String.self, forKey: .name)
                // 显式 null 不是无参数调用，不能与省略 args 混在一起。
                args = container.contains(.args) ? try container.decode(JSONValue.self, forKey: .args) : nil
            }
        }

        struct FunctionResponse: Codable {
            var id: String?
            let name: String
            let response: JSONValue
        }

        var text: String?
        var thought: Bool?
        var inlineData: InlineData?
        var functionCall: FunctionCall?
        var functionResponse: FunctionResponse?
        /// Gemini 3 调用函数时必须把它原样放回原来的位置，否则返回 400。
        var thoughtSignature: String?

        init(text: String, signature: String? = nil) {
            self.text = text
            self.thoughtSignature = signature
        }

        init(jpeg: Data) {
            self.inlineData = InlineData(mimeType: "image/jpeg", data: jpeg.base64EncodedString())
        }

        init(call: ToolCall) {
            self.functionCall = FunctionCall(id: call.hasServiceID ? call.id : nil, name: call.name, args: call.input)
            self.thoughtSignature = call.signature
        }

        /// 函数结果必须是 JSON 对象；工具给的不是对象时包一层 {"result": …}。
        init(result: ToolResult, callHasServiceID: Bool) {
            let value = JSONValue.parse(result.content) ?? .string(result.content)
            self.functionResponse = FunctionResponse(
                id: callHasServiceID ? result.callID : nil,
                name: result.name,
                response: value.objectValue != nil ? value : ["result": value]
            )
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

        /// Google 搜索接地（内容是空对象），或者 App 的函数工具。
        enum Tool: Encodable {
            case googleSearch
            case functions([ToolDefinition])

            private enum CodingKeys: String, CodingKey {
                case googleSearch = "google_search"
                case functionDeclarations
            }

            private struct Declaration: Encodable {
                let name: String
                let description: String
                let parameters: JSONValue
            }

            private struct Empty: Encodable {}

            func encode(to encoder: any Encoder) throws {
                var container = encoder.container(keyedBy: CodingKeys.self)
                switch self {
                case .googleSearch:
                    try container.encode(Empty(), forKey: .googleSearch)
                case let .functions(tools):
                    try container.encode(
                        tools.map { Declaration(name: $0.name, description: $0.description, parameters: $0.parameters) },
                        forKey: .functionDeclarations
                    )
                }
            }
        }

        let contents: [Content]
        let systemInstruction: Content?
        let generationConfig: GenerationConfig
        let tools: [Tool]?
    }

    public func makeURLRequest(for request: ChatRequest) throws -> URLRequest {
        for call in request.messages.flatMap(\.toolCalls) { _ = try call.validatedInput() }
        let model = request.model.hasPrefix("models/") ? String(request.model.dropFirst(7)) : request.model
        let url = baseURL
            .appending(path: "models/\(model):streamGenerateContent")
            .appending(queryItems: [URLQueryItem(name: "alt", value: "sse")])

        // 函数结果要不要带 ID，看对应的调用有没有服务商给的 ID。
        let serviceIDs = Set(request.messages.flatMap(\.toolCalls).filter(\.hasServiceID).map(\.id))
        var tools: [RequestBody.Tool] = request.webSearch ? [.googleSearch] : []
        if !request.tools.isEmpty { tools.append(.functions(request.tools)) }
        let body = RequestBody(
            contents: request.alternatingMessages.map { message in
                var parts = message.toolResults.map { Part(result: $0, callHasServiceID: serviceIDs.contains($0.callID)) }
                parts += message.images.map { Part(jpeg: $0) }
                // 不在函数调用上的签名放回文字那一块。
                let signature = message.thinking.compactMap(\.signature).first
                if !message.text.isEmpty || (parts.isEmpty && message.toolCalls.isEmpty) || (signature != nil && message.toolCalls.isEmpty) {
                    parts.append(Part(text: message.text, signature: signature))
                }
                parts += message.toolCalls.map { Part(call: $0) }
                return Content(role: message.role == .user ? "user" : "model", parts: parts)
            },
            systemInstruction: request.trimmedSystemPrompt.map { Content(role: nil, parts: [Part(text: $0)]) },
            generationConfig: .init(thinkingConfig: .init(
                includeThoughts: true,
                thinkingLevel: request.reasoningEffort?.rawValue
            )),
            tools: tools.isEmpty ? nil : tools
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
            let finishReason: String?
        }

        struct PromptFeedback: Decodable {
            let blockReason: String?
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
        let promptFeedback: PromptFeedback?
    }

    public static func decodeStreamData(_ data: String) throws -> StreamPayload {
        let decoder = StreamDecoder()
        let payload = try decoder.decode(data)
        try decoder.checkCompletionError()
        return payload
    }

    /// 结束原因与用量可能不在同一个片段里，到流尾再确认回答完整。
    public final class StreamDecoder: @unchecked Sendable {
        private var receivedEnd = false
        private var completionError: ChatServiceError?

        public init() {}

        public func decode(_ data: String) throws -> StreamPayload {
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
            if let reason = chunk.promptFeedback?.blockReason, !reason.isEmpty, reason != "BLOCK_REASON_UNSPECIFIED" {
                completionError = .blocked
            }
            if let reason = chunk.candidates?.first?.finishReason {
                receivedEnd = true
                switch reason {
                case "STOP": break
                case "MAX_TOKENS": completionError = .truncated
                case "SAFETY", "RECITATION", "BLOCKLIST", "PROHIBITED_CONTENT", "SPII", "IMAGE_SAFETY", "IMAGE_PROHIBITED_CONTENT":
                    completionError = .blocked
                case "MALFORMED_FUNCTION_CALL", "UNEXPECTED_TOOL_CALL": completionError = .invalidResponse
                default: completionError = .incompleteStream
                }
            }
            return .events(try GeminiService.events(from: chunk))
        }

        func checkCompletionError() throws {
            if let completionError { throw completionError }
        }

        func finishStream() throws -> [ChatStreamEvent] {
            try checkCompletionError()
            guard receivedEnd else { throw ChatServiceError.incompleteStream }
            return []
        }
    }

    private static func events(from chunk: StreamChunk) throws -> [ChatStreamEvent] {
        let parts = chunk.candidates?.first?.content?.parts ?? []
        var events: [ChatStreamEvent] = []
        for part in parts {
            if let call = part.functionCall {
                // 函数调用一次给完整。旧版本不给 ID，自己编一个，用来和结果对上。
                guard !call.name.isEmpty else { throw ChatServiceError.invalidResponse }
                let tool = ToolCall(
                    id: call.id ?? ToolCall.localIDPrefix + UUID().uuidString,
                    name: call.name,
                    arguments: (call.args ?? .object([:])).jsonString,
                    signature: part.thoughtSignature
                )
                _ = try tool.validatedInput()
                events.append(.toolCall(tool))
                continue
            }
            if let text = part.text, !text.isEmpty {
                events.append(part.thought == true ? .reasoning(text) : .text(text))
            }
            if let signature = part.thoughtSignature, !signature.isEmpty {
                events.append(.thinkingBlock(ThinkingBlock(text: "", signature: signature)))
            }
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
        return events
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
            let decoder = StreamDecoder()
            return SSEStreaming.stream(
                session: session,
                request: try makeURLRequest(for: request),
                decode: { try decoder.decode($0.data) },
                finish: { try decoder.finishStream() }
            )
        } catch {
            return AsyncThrowingStream { $0.finish(throwing: error) }
        }
    }
}
