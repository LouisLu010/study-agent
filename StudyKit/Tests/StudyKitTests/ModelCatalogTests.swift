import Foundation
import Testing
@testable import StudyKit

@Suite struct ModelCatalogTests {
    private func url(_ string: String) -> URL { URL(string: string)! }

    // MARK: 请求

    @Test func buildsOpenAIRequest() {
        let request = ModelCatalog.makeRequest(
            kind: .openAICompatible, baseURL: url("https://api.deepseek.com/v1"), apiKey: "sk", cursor: nil
        )
        #expect(request.url?.absoluteString == "https://api.deepseek.com/v1/models")
        #expect(request.httpMethod == "GET")
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer sk")
    }

    @Test func buildsAnthropicRequestWithCursor() {
        let first = ModelCatalog.makeRequest(
            kind: .anthropic, baseURL: url("https://api.anthropic.com/v1"), apiKey: "ak", cursor: nil
        )
        #expect(first.url?.absoluteString == "https://api.anthropic.com/v1/models?limit=1000")
        #expect(first.value(forHTTPHeaderField: "x-api-key") == "ak")
        #expect(first.value(forHTTPHeaderField: "anthropic-version") == AnthropicService.apiVersion)

        let next = ModelCatalog.makeRequest(
            kind: .anthropic, baseURL: url("https://api.anthropic.com/v1"), apiKey: "ak", cursor: "claude-x"
        )
        #expect(next.url?.absoluteString == "https://api.anthropic.com/v1/models?limit=1000&after_id=claude-x")
    }

    @Test func buildsGeminiRequestWithCursor() {
        let request = ModelCatalog.makeRequest(
            kind: .gemini,
            baseURL: url("https://generativelanguage.googleapis.com/v1beta"),
            apiKey: "gk",
            cursor: "tok"
        )
        #expect(
            request.url?.absoluteString
                == "https://generativelanguage.googleapis.com/v1beta/models?pageSize=1000&pageToken=tok"
        )
        #expect(request.value(forHTTPHeaderField: "x-goog-api-key") == "gk")
    }

    // MARK: 解析

    @Test func parsesOpenAIList() throws {
        let json = #"{"object":"list","data":[{"id":"gpt-4o","object":"model","owned_by":"openai"},{"id":"deepseek-chat"}]}"#
        let page = try ModelCatalog.parse(kind: .openAICompatible, data: Data(json.utf8))
        #expect(page.models == [RemoteModel(id: "gpt-4o"), RemoteModel(id: "deepseek-chat")])
        #expect(page.next == nil)
    }

    @Test func parsesOpenRouterNamesAndModalities() throws {
        let json = #"""
        {"data":[
          {"id":"openai/gpt-4o","name":"OpenAI: GPT-4o","architecture":{"input_modalities":["text","image"]}},
          {"id":"deepseek/deepseek-r1","name":"DeepSeek R1","architecture":{"input_modalities":["text"]}}
        ]}
        """#
        let page = try ModelCatalog.parse(kind: .openAICompatible, data: Data(json.utf8))
        #expect(page.models == [
            RemoteModel(id: "openai/gpt-4o", displayName: "OpenAI: GPT-4o", supportsImages: true),
            RemoteModel(id: "deepseek/deepseek-r1", displayName: "DeepSeek R1", supportsImages: false),
        ])
    }

    @Test func parsesAnthropicPages() throws {
        let more = #"{"data":[{"type":"model","id":"claude-opus-5-5","display_name":"Claude Opus 5.5"}],"has_more":true,"first_id":"claude-opus-5-5","last_id":"claude-opus-5-5"}"#
        let page = try ModelCatalog.parse(kind: .anthropic, data: Data(more.utf8))
        #expect(page.models == [RemoteModel(id: "claude-opus-5-5", displayName: "Claude Opus 5.5", supportsImages: true)])
        #expect(page.next == "claude-opus-5-5")

        let last = #"{"data":[],"has_more":false,"first_id":null,"last_id":null}"#
        #expect(try ModelCatalog.parse(kind: .anthropic, data: Data(last.utf8)).next == nil)
    }

    @Test func parsesGeminiAndSkipsNonChatModels() throws {
        let json = #"""
        {"models":[
          {"name":"models/gemini-3.8-flash","displayName":"Gemini 3.8 Flash","supportedGenerationMethods":["generateContent","countTokens"]},
          {"name":"models/text-embedding-004","displayName":"Text Embedding","supportedGenerationMethods":["embedContent"]}
        ],"nextPageToken":"abc"}
        """#
        let page = try ModelCatalog.parse(kind: .gemini, data: Data(json.utf8))
        #expect(page.models == [RemoteModel(id: "gemini-3.8-flash", displayName: "Gemini 3.8 Flash", supportsImages: true)])
        #expect(page.next == "abc")
    }

    @Test func rejectsUnexpectedResponse() {
        #expect(throws: ChatServiceError.invalidResponse) {
            try ModelCatalog.parse(kind: .openAICompatible, data: Data("<html>".utf8))
        }
    }

    @Test func validatesProviderBeforeFetching() async {
        await #expect(throws: ChatServiceError.missingAPIKey) {
            try await ModelCatalog.fetch(kind: .openAICompatible, baseURL: "https://a.com/v1", apiKey: "")
        }
        await #expect(throws: ChatServiceError.invalidBaseURL) {
            try await ModelCatalog.fetch(kind: .openAICompatible, baseURL: "http://a.com/v1", apiKey: "k")
        }
    }
}
