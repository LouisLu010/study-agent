import Foundation
import Testing
@testable import StudyKit

@Suite struct ToolArgumentsValidationTests {
    @Test(arguments: ["[]", "null", "1", #""text""#, #"{"question":1"#])
    func rejectsInvalidArguments(_ arguments: String) {
        let call = ToolCall(id: "a", name: "fetch_question", arguments: arguments)
        #expect(throws: ChatServiceError.invalidToolArguments(name: "fetch_question")) {
            try call.validatedInput()
        }
        #expect(call.input == .null)
    }

    @Test(arguments: ["", "  \n", "{}"])
    func supportsCallsWithoutArguments(_ arguments: String) throws {
        #expect(try ToolCall(id: "a", name: "finish_paper", arguments: arguments).validatedInput() == .object([:]))
    }

    @Test func allProvidersRejectInvalidHistoricalCalls() throws {
        let request = ChatRequest(model: "m", messages: [
            ChatMessage(role: .assistant, text: "", toolCalls: [ToolCall(id: "a", name: "finish_paper", arguments: "[]")])
        ])
        let baseURL = try #require(URL(string: "https://fixture.study.test/v1"))
        #expect(throws: ChatServiceError.invalidToolArguments(name: "finish_paper")) {
            try OpenAICompatibleService(baseURL: baseURL, apiKey: "test").makeURLRequest(for: request)
        }
        #expect(throws: ChatServiceError.invalidToolArguments(name: "finish_paper")) {
            try AnthropicService(baseURL: baseURL, apiKey: "test").makeURLRequest(for: request)
        }
        #expect(throws: ChatServiceError.invalidToolArguments(name: "finish_paper")) {
            try GeminiService(baseURL: baseURL, apiKey: "test").makeURLRequest(for: request)
        }
    }
}

@Suite struct ProviderStreamLifecycleTests {
    @Test(arguments: [#"{"number":"1"}"#, #"{"number":"#])
    func openAITruncationNeverFlushesTools(_ arguments: String) throws {
        let decoder = OpenAICompatibleService.StreamDecoder()
        let chunk: [String: Any] = ["choices": [["delta": ["tool_calls": [[
            "index": 0, "id": "a", "function": ["name": "fetch_question", "arguments": arguments]
        ]]], "finish_reason": "length"]]]
        let data = String(decoding: try JSONSerialization.data(withJSONObject: chunk), as: UTF8.self)
        #expect(try decoder.decode(data) == .events([]))
        #expect(throws: ChatServiceError.truncated) { try decoder.finish() }
        #expect(throws: ChatServiceError.truncated) { try decoder.finishStream() }
    }

    @Test func openAIRejectsInvalidCompletedToolArguments() {
        #expect(throws: ChatServiceError.invalidToolArguments(name: "finish_paper")) {
            try OpenAICompatibleService.decodeStreamData(#"{"choices":[{"delta":{"tool_calls":[{"index":0,"id":"a","function":{"name":"finish_paper","arguments":"[]"}}]},"finish_reason":"tool_calls"}]}"#)
        }
    }

    @Test func openAIAcceptsDoneWithoutFinishReasonButRejectsBareEOF() throws {
        let decoder = OpenAICompatibleService.StreamDecoder()
        _ = try decoder.decode(#"{"choices":[{"delta":{"content":"好"}}]}"#)
        #expect(throws: ChatServiceError.incompleteStream) { try decoder.finishStream() }
        #expect(try decoder.decode("[DONE]") == .done)
        #expect(try decoder.finishStream().isEmpty)
    }

    @Test func anthropicKeepsInitialToolInputAndRejectsInvalidInput() throws {
        let decoder = AnthropicService.StreamDecoder()
        _ = try decoder.decode(#"{"type":"content_block_start","index":0,"content_block":{"type":"tool_use","id":"a","name":"fetch_question","input":{"number":"17"}}}"#)
        let payload = try decoder.decode(#"{"type":"content_block_stop","index":0}"#)
        guard case let .events(events) = payload, case let .toolCall(call) = events.first else {
            Issue.record("工具调用没有发出")
            return
        }
        #expect(call.input["number"]?.stringValue == "17")
        _ = try decoder.decode(#"{"type":"content_block_start","index":1,"content_block":{"type":"tool_use","id":"b","name":"finish_paper","input":null}}"#)
        #expect(throws: ChatServiceError.invalidToolArguments(name: "finish_paper")) {
            try decoder.decode(#"{"type":"content_block_stop","index":1}"#)
        }
    }

    @Test func anthropicRejectsBrokenJSONDeltas() throws {
        let decoder = AnthropicService.StreamDecoder()
        _ = try decoder.decode(#"{"type":"content_block_start","index":0,"content_block":{"type":"tool_use","id":"a","name":"fetch_question","input":{}}}"#)
        _ = try decoder.decode(#"{"type":"content_block_delta","index":0,"delta":{"type":"input_json_delta","partial_json":"{\"number\":"}}"#)
        #expect(throws: ChatServiceError.invalidToolArguments(name: "fetch_question")) {
            try decoder.decode(#"{"type":"content_block_stop","index":0}"#)
        }
    }

    @Test func anthropicRequiresMessageStopAndRecognizesFailureReasons() throws {
        let decoder = AnthropicService.StreamDecoder()
        _ = try decoder.decode(#"{"type":"message_delta","delta":{"stop_reason":"end_turn"}}"#)
        #expect(throws: ChatServiceError.incompleteStream) { try decoder.finishStream() }
        _ = try decoder.decode(#"{"type":"message_stop"}"#)
        #expect(try decoder.finishStream().isEmpty)
        #expect(throws: ChatServiceError.truncated) {
            try AnthropicService.decodeStreamData(#"{"type":"message_delta","delta":{"stop_reason":"max_tokens"}}"#)
        }
        #expect(throws: ChatServiceError.blocked) {
            try AnthropicService.decodeStreamData(#"{"type":"message_delta","delta":{"stop_reason":"refusal"}}"#)
        }
    }

    @Test func geminiRequiresFinishReasonAndRecognizesFailureReasons() throws {
        let decoder = GeminiService.StreamDecoder()
        _ = try decoder.decode(#"{"candidates":[{"content":{"parts":[{"text":"好"}]}}]}"#)
        #expect(throws: ChatServiceError.incompleteStream) { try decoder.finishStream() }
        _ = try decoder.decode(#"{"candidates":[{"finishReason":"STOP"}]}"#)
        #expect(try decoder.finishStream().isEmpty)
        #expect(throws: ChatServiceError.truncated) {
            try GeminiService.decodeStreamData(#"{"candidates":[{"finishReason":"MAX_TOKENS"}]}"#)
        }
        #expect(throws: ChatServiceError.blocked) {
            try GeminiService.decodeStreamData(#"{"promptFeedback":{"blockReason":"SAFETY"}}"#)
        }
        #expect(throws: ChatServiceError.incompleteStream) {
            try GeminiService.decodeStreamData(#"{"candidates":[{"finishReason":"OTHER"}]}"#)
        }
    }

    @Test(arguments: ["null", "[]"])
    func geminiRejectsNonObjectToolArguments(_ arguments: String) {
        let data = #"{"candidates":[{"content":{"parts":[{"functionCall":{"name":"finish_paper","args":\#(arguments)}}]}}]}"#
        #expect(throws: ChatServiceError.invalidToolArguments(name: "finish_paper")) {
            try GeminiService.decodeStreamData(data)
        }
    }
}

/// 每个请求自己携带响应，避免并行测试共用全局 handler。
private final class StreamFixtureURLProtocol: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool {
        request.url?.host == "fixture.study.test"
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let url = request.url,
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let encoded = components.queryItems?.first(where: { $0.name == "body" })?.value,
              let body = Data(base64Encoded: encoded),
              let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "text/event-stream"])
        else {
            client?.urlProtocol(self, didFailWithError: ChatServiceError.invalidResponse)
            return
        }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: body)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

private actor ToolExecutionRecorder {
    var calls = 0
    func record() { calls += 1 }
}

@Suite struct SSEStreamLifecycleTests {
    private func fixture(_ body: String) throws -> (URLSession, URL) {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StreamFixtureURLProtocol.self]
        let session = URLSession(configuration: configuration)
        var components = try #require(URLComponents(string: "https://fixture.study.test/v1"))
        components.queryItems = [URLQueryItem(name: "body", value: Data(body.utf8).base64EncodedString())]
        return (session, try #require(components.url))
    }

    private func collect(_ stream: AsyncThrowingStream<ChatStreamEvent, any Error>) async throws -> [ChatStreamEvent] {
        var events: [ChatStreamEvent] = []
        for try await event in stream { events.append(event) }
        return events
    }

    @Test func openAIPreservesUsageAfterFinishReason() async throws {
        let body = "data: {\"choices\":[{\"delta\":{\"content\":\"好\"},\"finish_reason\":\"stop\"}]}\n\n"
            + "data: {\"choices\":[],\"usage\":{\"prompt_tokens\":10,\"completion_tokens\":2}}\n\n"
            + "data: [DONE]\n\n"
        let (session, url) = try fixture(body)
        defer { session.invalidateAndCancel() }
        let service = OpenAICompatibleService(baseURL: url, apiKey: "test", session: session)
        let events = try await collect(service.streamChat(ChatRequest(model: "m", messages: [])))
        #expect(events == [.text("好"), .usage(input: 10, output: 2)])
    }

    @Test func openAIRejectsTextWithoutAnEndMarker() async throws {
        let (session, url) = try fixture("data: {\"choices\":[{\"delta\":{\"content\":\"半句\"}}]}\n\n")
        defer { session.invalidateAndCancel() }
        let service = OpenAICompatibleService(baseURL: url, apiKey: "test", session: session)
        await #expect(throws: ChatServiceError.incompleteStream) {
            try await collect(service.streamChat(ChatRequest(model: "m", messages: [])))
        }
    }

    @Test func emptyCompletedResponseIsAnError() async throws {
        let (session, url) = try fixture("data: [DONE]\n\n")
        defer { session.invalidateAndCancel() }
        let service = OpenAICompatibleService(baseURL: url, apiKey: "test", session: session)
        await #expect(throws: ChatServiceError.emptyResponse) {
            try await collect(service.streamChat(ChatRequest(model: "m", messages: [])))
        }
    }

    @Test func reasoningWithoutAnAnswerIsAnError() async throws {
        let body = "data: {\"choices\":[{\"delta\":{\"reasoning_content\":\"想一想\"},\"finish_reason\":\"stop\"}]}\n\n"
            + "data: [DONE]\n\n"
        let (session, url) = try fixture(body)
        defer { session.invalidateAndCancel() }
        let service = OpenAICompatibleService(baseURL: url, apiKey: "test", session: session)
        await #expect(throws: ChatServiceError.emptyResponse) {
            try await collect(service.streamChat(ChatRequest(model: "m", messages: [])))
        }
    }

    @Test(arguments: ["openai", "anthropic", "gemini"])
    func truncationNeverExecutesTools(_ provider: String) async throws {
        let body: String
        switch provider {
        case "openai":
            body = "data: {\"choices\":[{\"delta\":{\"tool_calls\":[{\"index\":0,\"id\":\"a\",\"function\":{\"name\":\"finish_paper\",\"arguments\":\"{}\"}}]},\"finish_reason\":\"length\"}]}\n\n"
                + "data: [DONE]\n\n"
        case "anthropic":
            body = "data: {\"type\":\"content_block_start\",\"index\":0,\"content_block\":{\"type\":\"tool_use\",\"id\":\"a\",\"name\":\"finish_paper\",\"input\":{}}}\n\n"
                + "data: {\"type\":\"content_block_stop\",\"index\":0}\n\n"
                + "data: {\"type\":\"message_delta\",\"delta\":{\"stop_reason\":\"max_tokens\"}}\n\n"
                + "data: {\"type\":\"message_stop\"}\n\n"
        default:
            body = "data: {\"candidates\":[{\"content\":{\"parts\":[{\"functionCall\":{\"name\":\"finish_paper\",\"args\":{}}}]},\"finishReason\":\"MAX_TOKENS\"}]}\n\n"
        }
        let (session, url) = try fixture(body)
        defer { session.invalidateAndCancel() }
        let service: any ChatService
        switch provider {
        case "openai": service = OpenAICompatibleService(baseURL: url, apiKey: "test", session: session)
        case "anthropic": service = AnthropicService(baseURL: url, apiKey: "test", session: session)
        default: service = GeminiService(baseURL: url, apiKey: "test", session: session)
        }
        let recorder = ToolExecutionRecorder()
        await #expect(throws: ChatServiceError.truncated) {
            try await ToolLoop(maxCalls: 5).run(service: service, request: ChatRequest(model: "m", messages: [])) { _ in
                await recorder.record()
                return ToolLoop.Outcome(["ok": true], stop: true)
            }
        }
        #expect(await recorder.calls == 0)
    }

    @Test func anthropicCannotCompleteWithoutMessageStop() async throws {
        let (session, url) = try fixture("data: {\"type\":\"content_block_delta\",\"index\":0,\"delta\":{\"type\":\"text_delta\",\"text\":\"半句\"}}\n\n")
        defer { session.invalidateAndCancel() }
        let service = AnthropicService(baseURL: url, apiKey: "test", session: session)
        await #expect(throws: ChatServiceError.incompleteStream) {
            try await collect(service.streamChat(ChatRequest(model: "m", messages: [])))
        }
    }

    @Test func anthropicPreservesUsageAtCompletion() async throws {
        let body = "data: {\"type\":\"content_block_delta\",\"index\":0,\"delta\":{\"type\":\"text_delta\",\"text\":\"好\"}}\n\n"
            + "data: {\"type\":\"message_delta\",\"delta\":{\"stop_reason\":\"end_turn\"},\"usage\":{\"output_tokens\":2}}\n\n"
            + "data: {\"type\":\"message_stop\"}\n\n"
        let (session, url) = try fixture(body)
        defer { session.invalidateAndCancel() }
        let service = AnthropicService(baseURL: url, apiKey: "test", session: session)
        let events = try await collect(service.streamChat(ChatRequest(model: "m", messages: [])))
        #expect(events == [.text("好"), .usage(input: nil, output: 2)])
    }

    @Test func geminiPreservesUsageAfterStop() async throws {
        let body = "data: {\"candidates\":[{\"content\":{\"parts\":[{\"text\":\"好\"}]},\"finishReason\":\"STOP\"}]}\n\n"
            + "data: {\"usageMetadata\":{\"promptTokenCount\":10,\"candidatesTokenCount\":2}}\n\n"
        let (session, url) = try fixture(body)
        defer { session.invalidateAndCancel() }
        let service = GeminiService(baseURL: url, apiKey: "test", session: session)
        let events = try await collect(service.streamChat(ChatRequest(model: "m", messages: [])))
        #expect(events == [.text("好"), .usage(input: 10, output: 2)])
    }

    @Test func geminiCannotCompleteWithoutFinishReason() async throws {
        let (session, url) = try fixture("data: {\"candidates\":[{\"content\":{\"parts\":[{\"text\":\"半句\"}]}}]}\n\n")
        defer { session.invalidateAndCancel() }
        let service = GeminiService(baseURL: url, apiKey: "test", session: session)
        await #expect(throws: ChatServiceError.incompleteStream) {
            try await collect(service.streamChat(ChatRequest(model: "m", messages: [])))
        }
    }
}
