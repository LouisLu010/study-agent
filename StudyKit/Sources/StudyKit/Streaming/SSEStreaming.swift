import Foundation

/// 一个 SSE 事件解码后的结果。
public enum StreamPayload: Sendable, Equatable {
    case events([ChatStreamEvent])
    /// 服务商发来了结束标记。
    case done
}

/// 三种协议共用的流式请求：发送请求、处理 HTTP 错误、按 SSE 切分事件，再交给各协议的解码函数。
enum SSEStreaming {
    /// finish 在 EOF 或结束标记后调用，验证协议是否完成，并返回尚未发出的事件。
    static func stream(
        session: URLSession,
        request: URLRequest,
        decode: @escaping @Sendable (SSEEvent) throws -> StreamPayload,
        finish: (@Sendable () throws -> [ChatStreamEvent])? = nil
    ) -> AsyncThrowingStream<ChatStreamEvent, any Error> {
        var request = request
        // 推理模型可能思考很久才输出第一个字，默认的 60 秒空闲超时不够。
        request.timeoutInterval = 300
        return AsyncThrowingStream { [request] continuation in
            let task = Task {
                do {
                    try Task.checkCancellation()
                    let (bytes, response) = try await session.bytes(for: request)
                    guard let http = response as? HTTPURLResponse else {
                        throw ChatServiceError.invalidResponse
                    }
                    guard (200..<300).contains(http.statusCode) else {
                        var body = Data()
                        for try await byte in bytes {
                            body.append(byte)
                            if body.count > 64 * 1024 { break }
                        }
                        let message = APIErrorMessage.extract(from: body)
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
                    var hasResponse = false

                    for try await byte in bytes {
                        try Task.checkCancellation()
                        guard let line = splitter.append(byte),
                              let event = parser.feed(line)
                        else { continue }
                        if try forward(decode(event), to: continuation, hasResponse: &hasResponse) {
                            isDone = true
                            break
                        }
                    }

                    if !isDone {
                        if let line = splitter.finish(), let event = parser.feed(line) {
                            isDone = try forward(decode(event), to: continuation, hasResponse: &hasResponse)
                        }
                        if !isDone, let event = parser.finish() {
                            isDone = try forward(decode(event), to: continuation, hasResponse: &hasResponse)
                        }
                    }
                    try Task.checkCancellation()
                    guard isDone || finish != nil else { throw ChatServiceError.incompleteStream }
                    _ = forward(.events(try finish?() ?? []), to: continuation, hasResponse: &hasResponse)
                    guard hasResponse else { throw ChatServiceError.emptyResponse }
                    try Task.checkCancellation()
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// 返回 `true` 表示收到了结束标记。
    private static func forward(
        _ payload: StreamPayload,
        to continuation: AsyncThrowingStream<ChatStreamEvent, any Error>.Continuation,
        hasResponse: inout Bool
    ) -> Bool {
        switch payload {
        case .done:
            return true
        case let .events(events):
            for event in events {
                switch event {
                case let .text(text):
                    hasResponse = hasResponse || !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                case .toolCall:
                    hasResponse = true
                default: break
                }
                continuation.yield(event)
            }
            return false
        }
    }
}

public enum APIErrorMessage {
    /// 从错误响应的 JSON 中取出错误信息。
    /// 兼容 `{"error":{"message":…}}`（OpenAI、Anthropic、Gemini）、`{"error":"…"}` 和 `{"message":…}`。
    public static func extract(from data: Data) -> String? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        if let error = object["error"] as? [String: Any] {
            return (error["message"] as? String) ?? "未知错误"
        }
        if let error = object["error"] as? String {
            return error
        }
        if object["choices"] == nil, object["candidates"] == nil, let message = object["message"] as? String {
            return message
        }
        return nil
    }
}
