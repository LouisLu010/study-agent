import Foundation

/// 一个 SSE 事件解码后的结果。
public enum StreamPayload: Sendable, Equatable {
    case events([ChatStreamEvent])
    /// 服务商发来了结束标记。
    case done
}

/// 三种协议共用的流式请求：发送请求、处理 HTTP 错误、按 SSE 切分事件，再交给各协议的解码函数。
enum SSEStreaming {
    static func stream(
        session: URLSession,
        request: URLRequest,
        decode: @escaping @Sendable (SSEEvent) throws -> StreamPayload
    ) -> AsyncThrowingStream<ChatStreamEvent, any Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
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

                    for try await byte in bytes {
                        guard let line = splitter.append(byte),
                              let event = parser.feed(line)
                        else { continue }
                        if try forward(decode(event), to: continuation) {
                            isDone = true
                            break
                        }
                    }

                    if !isDone {
                        if let line = splitter.finish(), let event = parser.feed(line) {
                            isDone = try forward(decode(event), to: continuation)
                        }
                        if !isDone, let event = parser.finish() {
                            _ = try forward(decode(event), to: continuation)
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

    /// 返回 `true` 表示收到了结束标记。
    private static func forward(
        _ payload: StreamPayload,
        to continuation: AsyncThrowingStream<ChatStreamEvent, any Error>.Continuation
    ) -> Bool {
        switch payload {
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
