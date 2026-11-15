import Foundation
import Testing
@testable import StudyKit

@Suite struct OpenAICompatibleServiceTests {
    private func service(_ base: String = "https://api.example.com/v1") -> OpenAICompatibleService {
        OpenAICompatibleService(baseURL: URL(string: base)!, apiKey: "sk-test")
    }

    private func bodyJSON(_ request: URLRequest) throws -> [String: Any] {
        let body = try #require(request.httpBody)
        return try #require(JSONSerialization.jsonObject(with: body) as? [String: Any])
    }

    // MARK: 请求

    @Test func buildsStreamingRequest() throws {
        let request = try service().makeURLRequest(for: ChatRequest(
            model: "gpt-test",
            systemPrompt: "规则",
            messages: [ChatMessage(role: .user, text: "你好"), ChatMessage(role: .assistant, text: "嗨")]
        ))

        #expect(request.url?.absoluteString == "https://api.example.com/v1/chat/completions")
        #expect(request.httpMethod == "POST")
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer sk-test")
        #expect(request.value(forHTTPHeaderField: "Content-Type") == "application/json")

        let json = try bodyJSON(request)
        #expect(json["model"] as? String == "gpt-test")
        #expect(json["stream"] as? Bool == true)
        let messages = try #require(json["messages"] as? [[String: String]])
        #expect(messages == [
            ["role": "system", "content": "规则"],
            ["role": "user", "content": "你好"],
            ["role": "assistant", "content": "嗨"],
        ])
    }

    @Test func handlesTrailingSlashInBaseURL() throws {
        let request = try service("https://api.example.com/v1/").makeURLRequest(
            for: ChatRequest(model: "m", messages: [])
        )
        #expect(request.url?.absoluteString == "https://api.example.com/v1/chat/completions")
    }

    @Test func omitsBlankSystemPrompt() throws {
        let request = try service().makeURLRequest(
            for: ChatRequest(model: "m", systemPrompt: "  \n", messages: [ChatMessage(role: .user, text: "q")])
        )
        let messages = try #require(try bodyJSON(request)["messages"] as? [[String: String]])
        #expect(messages == [["role": "user", "content": "q"]])
    }

    // MARK: 流式数据

    @Test func decodesTextDelta() throws {
        let payload = try OpenAICompatibleService.decodeStreamData(
            #"{"choices":[{"index":0,"delta":{"content":"你好"},"finish_reason":null}]}"#
        )
        #expect(payload == .events([.text("你好")]))
    }

    @Test func decodesDeepSeekReasoning() throws {
        let payload = try OpenAICompatibleService.decodeStreamData(
            #"{"choices":[{"delta":{"content":null,"reasoning_content":"先想想"}}]}"#
        )
        #expect(payload == .events([.reasoning("先想想")]))
    }

    @Test func decodesOpenRouterReasoning() throws {
        let payload = try OpenAICompatibleService.decodeStreamData(
            #"{"choices":[{"delta":{"reasoning":"嗯"}}]}"#
        )
        #expect(payload == .events([.reasoning("嗯")]))
    }

    @Test func ignoresEmptyChunks() throws {
        #expect(try OpenAICompatibleService.decodeStreamData(#"{"choices":[]}"#) == .events([]))
        #expect(try OpenAICompatibleService.decodeStreamData(
            #"{"choices":[{"delta":{"role":"assistant","content":""}}]}"#
        ) == .events([]))
    }

    @Test func recognizesDone() throws {
        #expect(try OpenAICompatibleService.decodeStreamData("[DONE]") == .done)
    }

    @Test func throwsOnErrorChunk() {
        #expect(throws: ChatServiceError.server(message: "额度不足")) {
            try OpenAICompatibleService.decodeStreamData(#"{"error":{"message":"额度不足","code":402}}"#)
        }
    }

    @Test func throwsOnMalformedData() {
        #expect(throws: ChatServiceError.invalidResponse) {
            try OpenAICompatibleService.decodeStreamData("not json")
        }
    }

    // MARK: 错误信息

    @Test func extractsErrorMessages() {
        #expect(OpenAICompatibleService.errorMessage(
            from: Data(#"{"error":{"message":"Invalid API key"}}"#.utf8)
        ) == "Invalid API key")
        #expect(OpenAICompatibleService.errorMessage(from: Data(#"{"error":"bad"}"#.utf8)) == "bad")
        #expect(OpenAICompatibleService.errorMessage(from: Data(#"{"message":"nope"}"#.utf8)) == "nope")
        #expect(OpenAICompatibleService.errorMessage(from: Data("<html>".utf8)) == nil)
    }
}

@Suite struct ChatServiceFactoryTests {
    @Test func rejectsMissingKey() {
        #expect(throws: ChatServiceError.missingAPIKey) {
            try ChatServiceFactory.makeService(kind: .openAICompatible, baseURL: "https://a.com/v1", apiKey: "  ")
        }
    }

    @Test func rejectsNonHTTPSAddress() {
        #expect(throws: ChatServiceError.invalidBaseURL) {
            try ChatServiceFactory.makeService(kind: .openAICompatible, baseURL: "http://a.com/v1", apiKey: "k")
        }
        #expect(throws: ChatServiceError.invalidBaseURL) {
            try ChatServiceFactory.makeService(kind: .openAICompatible, baseURL: "api.openai.com", apiKey: "k")
        }
    }

    @Test func createsOpenAIService() throws {
        let service = try ChatServiceFactory.makeService(
            kind: .openAICompatible, baseURL: " https://api.deepseek.com/v1 ", apiKey: " sk-1 "
        )
        let openAI = try #require(service as? OpenAICompatibleService)
        #expect(openAI.baseURL.absoluteString == "https://api.deepseek.com/v1")
        #expect(openAI.apiKey == "sk-1")
    }
}

@Suite struct SystemPromptTests {
    @Test func appendsCustomInstructions() {
        #expect(SystemPrompt.compose(customInstructions: "  ") == SystemPrompt.builtInRules)
        #expect(SystemPrompt.compose(customInstructions: "我是高二学生").hasSuffix("我是高二学生"))
    }
}
