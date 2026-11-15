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
            let content: String
        }

        let model: String
        let messages: [Message]
        let stream: Bool
    }

    public func makeURLRequest(for request: ChatRequest) throws -> URLRequest {
        var messages: [RequestBody.Message] = []
        if let system = request.systemPrompt?.trimmingCharacters(in: .whitespacesAndNewlines), !system.isEmpty {
            messages.append(.init(role: "system", content: system))
        }
        messages += request.messages.map { .init(role: $0.role.rawValue, content: $0.text) }

        var urlRequest = URLRequest(url: baseURL.appending(path: "chat/completions"))
        urlRequest.httpMethod = "POST"
        urlRequest.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        urlRequest.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        urlRequest.httpBody = try JSONEncoder().encode(
            RequestBody(model: request.model, messages: messages, stream: true)
        )
        return urlRequest
    }

    // MARK: - 响应解析

    public enum StreamPayload: Sendable, Equatable {
        case events([ChatStreamEvent])
        case done
    }

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
        if let message = errorMessage(from: bytes) {
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

    /// 从错误响应的 JSON 中取出错误信息。兼容 `{"error":{"message":…}}`、`{"error":"…"}` 和 `{"message":…}`。
    public static func errorMessage(from data: Data) -> String? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        if let error = object["error"] as? [String: Any] {
            return (error["message"] as? String) ?? "未知错误"
        }
        if let error = object["error"] as? String {
            return error
        }
        if object["choices"] == nil, let message = object["message"] as? String {
            return message
        }
        return nil
    }

    // MARK: - 流式请求

    public func streamChat(_ request: ChatRequest) -> AsyncThrowingStream<ChatStreamEvent, any Error> {
        let urlRequest: URLRequest
        do {
            urlRequest = try makeURLRequest(for: request)
        } catch {
            return AsyncThrowingStream { $0.finish(throwing: error) }
        }

        let session = session
        return AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let (bytes, response) = try await session.bytes(for: urlRequest)
                    guard let http = response as? HTTPURLResponse else {
                        throw ChatServiceError.invalidResponse
                    }
                    guard (200..<300).contains(http.statusCode) else {
                        var body = Data()
                        for try await byte in bytes {
                            body.append(byte)
                            if body.count > 64 * 1024 { break }
                        }
                        let message = Self.errorMessage(from: body)
                            ?? String(decoding: body, as: UTF8.self)
                                .trimmingCharacters(in: .whitespacesAndNewlines)
                        throw ChatServiceError.http(
                            status: http.statusCode,
                            message: message.isEmpty ? nil : String(message.prefix(300))
                        )
                    }

                    var splitter = LineSplitter()
                    var parser = SSEParser()
                    var isDone = false

                    for try await byte in bytes {
                        guard let line = splitter.append(byte),
                              let event = parser.feed(line)
                        else { continue }
                        if try Self.forward(event, to: continuation) {
                            isDone = true
                            break
                        }
                    }

                    if !isDone {
                        if let line = splitter.finish(), let event = parser.feed(line) {
                            isDone = try Self.forward(event, to: continuation)
                        }
                        if !isDone, let event = parser.finish() {
                            _ = try Self.forward(event, to: continuation)
                        }
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// 把一个 SSE 事件转发给调用方。返回 `true` 表示收到了结束标记。
    private static func forward(
        _ event: SSEEvent,
        to continuation: AsyncThrowingStream<ChatStreamEvent, any Error>.Continuation
    ) throws -> Bool {
        switch try decodeStreamData(event.data) {
        case .done:
            return true
        case let .events(events):
            for event in events {
                continuation.yield(event)
            }
            return false
        }
    }
}
