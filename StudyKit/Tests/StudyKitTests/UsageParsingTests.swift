import Foundation
import Testing
@testable import StudyKit

@Suite struct UsageParsingTests {
    @Test func openAIRequestsUsageAndParsesFinalChunk() throws {
        let service = OpenAICompatibleService(baseURL: URL(string: "https://a.com/v1")!, apiKey: "k")
        let request = try service.makeURLRequest(for: ChatRequest(model: "m", messages: []))
        let json = try #require(JSONSerialization.jsonObject(with: #require(request.httpBody)) as? [String: Any])
        #expect(json["stream_options"] as? [String: Bool] == ["include_usage": true])

        let payload = try OpenAICompatibleService.decodeStreamData(
            #"{"choices":[],"usage":{"prompt_tokens":120,"completion_tokens":45,"total_tokens":165}}"#
        )
        #expect(payload == .events([.usage(input: 120, output: 45)]))
    }

    @Test func anthropicGivesInputFirstThenOutput() throws {
        let start = try AnthropicService.decodeStreamData(
            #"{"type":"message_start","message":{"id":"m","usage":{"input_tokens":30,"cache_read_input_tokens":70,"output_tokens":1}}}"#
        )
        #expect(start == .events([.usage(input: 100, output: nil)]))
        let delta = try AnthropicService.decodeStreamData(
            #"{"type":"message_delta","delta":{"stop_reason":"end_turn"},"usage":{"output_tokens":512}}"#
        )
        #expect(delta == .events([.usage(input: nil, output: 512)]))
    }

    @Test func geminiCountsThoughtsAsOutput() throws {
        let payload = try GeminiService.decodeStreamData(
            #"{"candidates":[{"content":{"parts":[{"text":"答"}]}}],"usageMetadata":{"promptTokenCount":50,"candidatesTokenCount":20,"thoughtsTokenCount":80}}"#
        )
        #expect(payload == .events([.text("答"), .usage(input: 50, output: 100)]))
    }
}
