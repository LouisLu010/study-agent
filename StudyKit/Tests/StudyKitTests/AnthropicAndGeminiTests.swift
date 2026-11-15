import Foundation
import Testing
@testable import StudyKit

private func bodyJSON(_ request: URLRequest) throws -> [String: Any] {
    let body = try #require(request.httpBody)
    return try #require(JSONSerialization.jsonObject(with: body) as? [String: Any])
}

private let conversation = ChatRequest(
    model: "test-model",
    systemPrompt: "规则",
    messages: [
        ChatMessage(role: .user, text: "第一问"),
        ChatMessage(role: .user, text: "补充"),
        ChatMessage(role: .assistant, text: "答"),
        ChatMessage(role: .user, text: "第二问"),
    ]
)

@Suite struct ChatRequestTests {
    @Test func mergesConsecutiveMessagesFromSameRole() {
        #expect(conversation.alternatingMessages == [
            ChatMessage(role: .user, text: "第一问\n\n补充"),
            ChatMessage(role: .assistant, text: "答"),
            ChatMessage(role: .user, text: "第二问"),
        ])
    }
}

@Suite struct AnthropicServiceTests {
    private let service = AnthropicService(baseURL: URL(string: "https://api.anthropic.com/v1")!, apiKey: "sk-ant")

    @Test func buildsRequest() throws {
        let request = try service.makeURLRequest(for: conversation)
        #expect(request.url?.absoluteString == "https://api.anthropic.com/v1/messages")
        #expect(request.value(forHTTPHeaderField: "x-api-key") == "sk-ant")
        #expect(request.value(forHTTPHeaderField: "anthropic-version") == "2023-06-01")

        let json = try bodyJSON(request)
        #expect(json["model"] as? String == "test-model")
        #expect(json["system"] as? String == "规则")
        #expect(json["stream"] as? Bool == true)
        #expect(json["max_tokens"] as? Int == AnthropicService.maxTokens)
        #expect(json["thinking"] == nil)
        #expect(json["output_config"] == nil)
        let messages = try #require(json["messages"] as? [[String: Any]])
        #expect(messages.map { $0["role"] as? String } == ["user", "assistant", "user"])
        let firstContent = try #require(messages.first?["content"] as? [[String: Any]])
        #expect(firstContent.count == 1)
        #expect(firstContent.first?["type"] as? String == "text")
        #expect(firstContent.first?["text"] as? String == "第一问\n\n补充")
    }

    @Test func encodesImagesBeforeText() throws {
        let request = ChatRequest(model: "m", messages: [
            ChatMessage(role: .user, text: "这道题怎么做", images: [Data([1, 2, 3])]),
            ChatMessage(role: .assistant, text: "好"),
            ChatMessage(role: .user, text: "", images: [Data([4])]),
        ])
        let messages = try #require(try bodyJSON(service.makeURLRequest(for: request))["messages"] as? [[String: Any]])
        let first = try #require(messages[0]["content"] as? [[String: Any]])
        #expect(first.map { $0["type"] as? String } == ["image", "text"])
        let source = try #require(first[0]["source"] as? [String: String])
        #expect(source == ["type": "base64", "media_type": "image/jpeg", "data": Data([1, 2, 3]).base64EncodedString()])
        // 只有图片没有文字时不发空的文字块
        let last = try #require(messages[2]["content"] as? [[String: Any]])
        #expect(last.map { $0["type"] as? String } == ["image"])
    }

    @Test func enablesThinkingWhenEffortIsSet() throws {
        var request = conversation
        request.reasoningEffort = .medium
        let json = try bodyJSON(service.makeURLRequest(for: request))
        #expect(json["thinking"] as? [String: String] == ["type": "adaptive", "display": "summarized"])
        #expect(json["output_config"] as? [String: String] == ["effort": "medium"])
    }

    @Test func decodesTextAndThinkingDeltas() throws {
        #expect(try AnthropicService.decodeStreamData(
            #"{"type":"content_block_delta","index":1,"delta":{"type":"text_delta","text":"答案是 21"}}"#
        ) == .events([.text("答案是 21")]))
        #expect(try AnthropicService.decodeStreamData(
            #"{"type":"content_block_delta","index":0,"delta":{"type":"thinking_delta","thinking":"用辗转相除法"}}"#
        ) == .events([.reasoning("用辗转相除法")]))
    }

    @Test func ignoresOtherEvents() throws {
        #expect(try AnthropicService.decodeStreamData(
            #"{"type":"message_start","message":{"id":"msg_1","content":[]}}"#
        ) == .events([]))
        #expect(try AnthropicService.decodeStreamData(
            #"{"type":"content_block_delta","index":0,"delta":{"type":"signature_delta","signature":"Eq"}}"#
        ) == .events([]))
        #expect(try AnthropicService.decodeStreamData(
            #"{"type":"content_block_delta","index":0,"delta":{"type":"thinking_delta","thinking":""}}"#
        ) == .events([]))
        #expect(try AnthropicService.decodeStreamData(#"{"type":"ping"}"#) == .events([]))
    }

    @Test func recognizesStopAndErrors() throws {
        #expect(try AnthropicService.decodeStreamData(#"{"type":"message_stop"}"#) == .done)
        #expect(throws: ChatServiceError.server(message: "Overloaded")) {
            try AnthropicService.decodeStreamData(
                #"{"type":"error","error":{"type":"overloaded_error","message":"Overloaded"}}"#
            )
        }
    }
}

@Suite struct GeminiServiceTests {
    private let service = GeminiService(
        baseURL: URL(string: "https://generativelanguage.googleapis.com/v1beta")!,
        apiKey: "g-key"
    )

    @Test func buildsRequest() throws {
        let request = try service.makeURLRequest(for: conversation)
        #expect(
            request.url?.absoluteString
                == "https://generativelanguage.googleapis.com/v1beta/models/test-model:streamGenerateContent?alt=sse"
        )
        #expect(request.value(forHTTPHeaderField: "x-goog-api-key") == "g-key")

        let json = try bodyJSON(request)
        let contents = try #require(json["contents"] as? [[String: Any]])
        #expect(contents.map { $0["role"] as? String } == ["user", "model", "user"])
        let firstParts = try #require(contents.first?["parts"] as? [[String: Any]])
        #expect(firstParts.first?["text"] as? String == "第一问\n\n补充")
        #expect(firstParts.first?["thought"] == nil)

        let system = try #require(json["systemInstruction"] as? [String: Any])
        #expect((system["parts"] as? [[String: Any]])?.first?["text"] as? String == "规则")

        let config = try #require(json["generationConfig"] as? [String: Any])
        let thinking = try #require(config["thinkingConfig"] as? [String: Any])
        #expect(thinking["includeThoughts"] as? Bool == true)
        #expect(thinking["thinkingLevel"] == nil)
    }

    @Test func stripsModelsPrefixAndSendsThinkingLevel() throws {
        var request = conversation
        request.model = "models/gemini-x"
        request.reasoningEffort = .low
        let urlRequest = try service.makeURLRequest(for: request)
        #expect(urlRequest.url?.path().hasSuffix("/models/gemini-x:streamGenerateContent") == true)
        let config = try #require(try bodyJSON(urlRequest)["generationConfig"] as? [String: Any])
        #expect((config["thinkingConfig"] as? [String: Any])?["thinkingLevel"] as? String == "low")
    }

    @Test func encodesImagesAsInlineData() throws {
        let request = ChatRequest(model: "m", messages: [
            ChatMessage(role: .user, text: "看图", images: [Data([9])]),
        ])
        let json = try bodyJSON(service.makeURLRequest(for: request))
        let contents = try #require(json["contents"] as? [[String: Any]])
        let parts = try #require(contents.first?["parts"] as? [[String: Any]])
        #expect(parts.count == 2)
        #expect(parts[0]["inlineData"] as? [String: String] == ["mimeType": "image/jpeg", "data": Data([9]).base64EncodedString()])
        #expect(parts[1]["text"] as? String == "看图")
    }

    @Test func decodesThoughtAndTextParts() throws {
        let payload = try GeminiService.decodeStreamData(
            #"{"candidates":[{"content":{"role":"model","parts":[{"text":"先分析","thought":true},{"text":"结论"}]}}]}"#
        )
        #expect(payload == .events([.reasoning("先分析"), .text("结论")]))
    }

    @Test func handlesEmptyChunksAndErrors() throws {
        #expect(try GeminiService.decodeStreamData(#"{"candidates":[{"finishReason":"STOP"}]}"#) == .events([]))
        #expect(throws: ChatServiceError.server(message: "API key not valid")) {
            try GeminiService.decodeStreamData(#"{"error":{"code":400,"message":"API key not valid"}}"#)
        }
    }
}
