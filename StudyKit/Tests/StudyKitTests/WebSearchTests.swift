import Foundation
import Testing
@testable import StudyKit

private func bodyJSON(_ request: URLRequest) throws -> [String: Any] {
    let body = try #require(request.httpBody)
    return try #require(JSONSerialization.jsonObject(with: body) as? [String: Any])
}

private let question = [ChatMessage(role: .user, text: "2025 年高考全国甲卷化学第 36 题")]

@Suite struct WebSearchRecorderTests {
    private let a = WebSource(url: "https://a.com/1", title: "A")
    private let b = WebSource(url: "https://b.com/2", title: "B")

    @Test func numbersEndCitationsInOrderAndReusesNumbers() {
        var recorder = WebSearchRecorder()
        var content = "第一句。"
        content += recorder.handle(.citations([Citation(sources: [a], anchor: .end)]), content: content) ?? ""
        content += "第二句。"
        content += recorder.handle(.citations([Citation(sources: [b, a], anchor: .end)]), content: content) ?? ""
        #expect(content == "第一句。[[1]](<https://a.com/1>)第二句。[[2]](<https://b.com/2>)[[1]](<https://a.com/1>)")
        #expect(recorder.record.sources == [a, b])
    }

    @Test func doesNotRepeatTheSameMarkerTwiceInARow() {
        var recorder = WebSearchRecorder()
        var content = "结论。"
        content += recorder.handle(.citations([Citation(sources: [a], anchor: .end)]), content: content) ?? ""
        #expect(recorder.handle(.citations([Citation(sources: [a], anchor: .end)]), content: content) == nil)
    }

    @Test func recordsQueriesResultsAndCount() {
        var recorder = WebSearchRecorder()
        _ = recorder.handle(.searching(query: nil), content: "")
        _ = recorder.handle(.searching(query: " 有机推断 "), content: "")
        _ = recorder.handle(.searching(query: "有机推断"), content: "")
        _ = recorder.handle(.searchResults([a, b, a]), content: "")
        _ = recorder.handle(.searchCount(2), content: "")
        _ = recorder.handle(.searchCount(1), content: "")
        #expect(recorder.record.queries == ["有机推断"])
        #expect(recorder.record.results == [a, b])
        #expect(recorder.record.count == 2)
        // 没有引用时用搜索结果作为出处。
        #expect(recorder.record.displayedSources == [a, b])
    }

    @Test func insertsOffsetCitationsByUnicodeScalar() {
        var recorder = WebSearchRecorder()
        // "冰岛😀人口" 的第 3 个字符之后（😀 算一个字符）。
        _ = recorder.handle(.citations([
            Citation(sources: [b], anchor: .offset(5)),
            Citation(sources: [a], anchor: .offset(3)),
        ]), content: "")
        let result = recorder.finish(content: "冰岛😀人口")
        #expect(result == "冰岛😀[[1]](<https://a.com/1>)人口[[2]](<https://b.com/2>)")
        #expect(recorder.record.sources == [a, b])
    }

    @Test func skipsMarkersWhenLinkAlreadyInTextOrInsideCodeBlock() {
        var recorder = WebSearchRecorder()
        let content = "见 [A](https://a.com/1)。\n```quiz\n{\"q\":1}\n```\n"
        _ = recorder.handle(.citations([
            Citation(sources: [a], anchor: .offset(5)),
            Citation(sources: [b], anchor: .offset(content.unicodeScalars.count - 6)),
        ]), content: "")
        #expect(recorder.finish(content: content) == content)
        // 两个网页都仍然列在出处里。
        #expect(recorder.record.sources == [a, b])
    }

    @Test func insertsAfterMatchingText() {
        var recorder = WebSearchRecorder()
        _ = recorder.handle(.citations([
            Citation(sources: [a], anchor: .afterText("人口约 39 万")),
            Citation(sources: [a, b], anchor: .afterText("面积 10 万平方公里")),
            Citation(sources: [b], anchor: .afterText("找不到的句子")),
        ]), content: "")
        let result = recorder.finish(content: "冰岛人口约 39 万，面积 10 万平方公里。")
        #expect(result == "冰岛人口约 39 万[[1]](<https://a.com/1>)，面积 10 万平方公里[[1]](<https://a.com/1>)[[2]](<https://b.com/2>)。")
    }

    @Test func recordRoundTripsAndFormatsSources() throws {
        var record = WebSearchRecord()
        #expect(record.encode() == "")
        record.queries = ["q"]
        record.sources = [a, WebSource(url: "https://www.c.org/x", title: "")]
        let decoded = try #require(WebSearchRecord.decode(record.encode()))
        #expect(decoded == record)
        #expect(decoded.effectiveCount == 1)
        #expect(decoded.sourcesText == "出处：\n[1] A https://a.com/1\n[2] c.org https://www.c.org/x")
    }

    @Test func resolvesDialect() {
        #expect(WebSearchDialect.resolve(raw: "", modelID: "deepseek-flash", baseURL: "https://relay.example.com/v1") == .deepSeek)
        #expect(WebSearchDialect.resolve(raw: "", modelID: "chat", baseURL: "https://api.deepseek.com") == .deepSeek)
        #expect(WebSearchDialect.resolve(raw: "", modelID: "gpt-5-search-api", baseURL: "https://api.openai.com/v1") == .openAI)
        #expect(WebSearchDialect.resolve(raw: "openAI", modelID: "deepseek-flash", baseURL: "") == .openAI)
    }
}

@Suite struct AnthropicWebSearchTests {
    private let service = AnthropicService(baseURL: URL(string: "https://api.anthropic.com/v1")!, apiKey: "k")

    @Test func declaresWebSearchToolOnlyWhenEnabled() throws {
        let off = try bodyJSON(service.makeURLRequest(for: ChatRequest(model: "m", messages: question)))
        #expect(off["tools"] == nil)
        let on = try bodyJSON(service.makeURLRequest(for: ChatRequest(model: "m", messages: question, webSearch: true)))
        let tools = try #require(on["tools"] as? [[String: Any]])
        #expect(tools.count == 1)
        #expect(tools[0]["type"] as? String == "web_search_20250305")
        #expect(tools[0]["name"] as? String == "web_search")
        #expect(tools[0]["max_uses"] as? Int == AnthropicService.maxWebSearches)
    }

    @Test func decodesSearchQueryResultsCitationsAndCount() throws {
        let decoder = AnthropicService.StreamDecoder()
        #expect(try decoder.decode(
            #"{"type":"content_block_start","index":0,"content_block":{"type":"server_tool_use","id":"srvtoolu_1","name":"web_search","input":{}}}"#
        ) == .events([.searching(query: nil)]))
        #expect(try decoder.decode(
            #"{"type":"content_block_delta","index":0,"delta":{"type":"input_json_delta","partial_json":"{\"query\": \"2025 全国甲卷"}}"#
        ) == .events([]))
        #expect(try decoder.decode(
            #"{"type":"content_block_delta","index":0,"delta":{"type":"input_json_delta","partial_json":" 化学\"}"}}"#
        ) == .events([]))
        #expect(try decoder.decode(#"{"type":"content_block_stop","index":0}"#)
            == .events([.searching(query: "2025 全国甲卷 化学")]))

        #expect(try decoder.decode(
            #"{"type":"content_block_start","index":1,"content_block":{"type":"web_search_tool_result","tool_use_id":"srvtoolu_1","content":[{"type":"web_search_result","title":"试卷","url":"https://x.cn/a","encrypted_content":"E","page_age":null}]}}"#
        ) == .events([.searchResults([WebSource(url: "https://x.cn/a", title: "试卷")])]))
        #expect(try decoder.decode(#"{"type":"content_block_stop","index":1}"#) == .events([]))

        #expect(try decoder.decode(
            #"{"type":"content_block_start","index":2,"content_block":{"type":"text","text":""}}"#
        ) == .events([]))
        #expect(try decoder.decode(
            #"{"type":"content_block_delta","index":2,"delta":{"type":"citations_delta","citation":{"type":"web_search_result_location","url":"https://x.cn/a","title":"试卷","cited_text":"…","encrypted_index":"I"}}}"#
        ) == .events([]))
        #expect(try decoder.decode(
            #"{"type":"content_block_delta","index":2,"delta":{"type":"text_delta","text":"第 36 题考查有机合成。"}}"#
        ) == .events([.text("第 36 题考查有机合成。")]))
        #expect(try decoder.decode(#"{"type":"content_block_stop","index":2}"#)
            == .events([.citations([Citation(sources: [WebSource(url: "https://x.cn/a", title: "试卷")], anchor: .end)])]))

        #expect(try decoder.decode(
            #"{"type":"message_delta","delta":{"stop_reason":"end_turn"},"usage":{"output_tokens":80,"server_tool_use":{"web_search_requests":1}}}"#
        ) == .events([.usage(input: nil, output: 80), .searchCount(1)]))
    }

    @Test func treatsSearchErrorsAsNoResults() throws {
        #expect(try AnthropicService.decodeStreamData(
            #"{"type":"content_block_start","index":1,"content_block":{"type":"web_search_tool_result","tool_use_id":"t","content":{"type":"web_search_tool_result_error","error_code":"max_uses_exceeded"}}}"#
        ) == .events([]))
    }
}

@Suite struct OpenAICompatibleWebSearchTests {
    private let service = OpenAICompatibleService(baseURL: URL(string: "https://api.deepseek.com")!, apiKey: "k")

    @Test func declaresDeepSeekToolOrOpenAIOptions() throws {
        let off = try bodyJSON(service.makeURLRequest(for: ChatRequest(model: "deepseek-flash", messages: question)))
        #expect(off["tools"] == nil)
        #expect(off["web_search_options"] == nil)

        let deepSeek = try bodyJSON(service.makeURLRequest(for: ChatRequest(
            model: "deepseek-flash", messages: question, webSearch: true, webSearchDialect: .deepSeek
        )))
        #expect(deepSeek["tools"] as? [[String: String]] == [["type": "deepseek_web_search"]])
        #expect(deepSeek["web_search_options"] == nil)

        let openAI = try bodyJSON(service.makeURLRequest(for: ChatRequest(
            model: "gpt-5-search-api", messages: question, webSearch: true, webSearchDialect: .openAI
        )))
        #expect(openAI["tools"] == nil)
        #expect((openAI["web_search_options"] as? [String: Any])?.isEmpty == true)
    }

    @Test func decodesDeepSeekToolEvents() throws {
        #expect(try OpenAICompatibleService.decodeStreamData(
            #"{"choices":[{"index":0,"delta":{},"server_tool_event":{"type":"call_started","step":0,"call":{"index":0,"id":"s","type":"deepseek_web_search","kind":"search","action":{"type":"search","queries":["2025 甲卷 化学","有机推断"]}}}}]}"#
        ) == .events([.searching(query: "2025 甲卷 化学 / 有机推断")]))
        #expect(try OpenAICompatibleService.decodeStreamData(
            #"{"choices":[{"index":0,"delta":{},"server_tool_event":{"type":"call_completed","step":0,"call":{"index":0,"status":"completed","sources":[{"type":"url","url":"https://x.cn/a","title":"试卷","snippet":"…"}]}}}]}"#
        ) == .events([.searchResults([WebSource(url: "https://x.cn/a", title: "试卷")])]))
        // 打开网页不算搜索。
        #expect(try OpenAICompatibleService.decodeStreamData(
            #"{"choices":[{"index":0,"delta":{},"server_tool_event":{"type":"call_started","step":1,"call":{"action":{"type":"open_page","url":"https://x.cn/a"}}}}]}"#
        ) == .events([]))
    }

    @Test func decodesAnnotationsAndSearchUsage() throws {
        let payload = try OpenAICompatibleService.decodeStreamData(
            #"{"choices":[{"index":0,"delta":{"content":"。","annotations":[{"type":"url_citation","url_citation":{"url":"https://x.cn/a","title":"试卷","start_index":0,"end_index":12}}]},"finish_reason":"stop"}],"usage":{"prompt_tokens":10,"completion_tokens":5,"total_tokens":15,"server_tool_use":{"tool_search":2,"tool_fetch":1}}}"#
        )
        #expect(payload == .events([
            .text("。"),
            .citations([Citation(sources: [WebSource(url: "https://x.cn/a", title: "试卷")], anchor: .offset(12))]),
            .usage(input: 10, output: 5),
            .searchCount(2),
        ]))
    }

    @Test func ignoresMalformedExtensionFields() throws {
        #expect(try OpenAICompatibleService.decodeStreamData(
            #"{"choices":[{"delta":{"content":"好","annotations":"x"},"server_tool_event":[1]}]}"#
        ) == .events([.text("好")]))
    }
}

@Suite struct GeminiWebSearchTests {
    private let service = GeminiService(baseURL: URL(string: "https://generativelanguage.googleapis.com/v1beta")!, apiKey: "g")

    @Test func declaresGoogleSearchOnlyWhenEnabled() throws {
        let off = try bodyJSON(service.makeURLRequest(for: ChatRequest(model: "gemini-x", messages: question)))
        #expect(off["tools"] == nil)
        let on = try bodyJSON(service.makeURLRequest(for: ChatRequest(model: "gemini-x", messages: question, webSearch: true)))
        let tools = try #require(on["tools"] as? [[String: Any]])
        #expect(tools.count == 1)
        #expect((tools[0]["google_search"] as? [String: Any])?.isEmpty == true)
    }

    @Test func decodesGroundingMetadata() throws {
        let payload = try GeminiService.decodeStreamData(#"""
        {"candidates":[{"content":{"parts":[{"text":"人口约 39 万。"}]},"groundingMetadata":{
          "webSearchQueries":["冰岛人口","冰岛 2026 人口"],
          "groundingChunks":[{"web":{"uri":"https://v.example/1","title":"hagstofa.is"}},{"web":{"uri":"https://v.example/2","title":"wiki.org"}}],
          "groundingSupports":[{"segment":{"startIndex":0,"endIndex":17,"text":"人口约 39 万"},"groundingChunkIndices":[1,0,5]}]
        }}]}
        """#)
        let first = WebSource(url: "https://v.example/1", title: "hagstofa.is")
        let second = WebSource(url: "https://v.example/2", title: "wiki.org")
        #expect(payload == .events([
            .text("人口约 39 万。"),
            .searching(query: "冰岛人口"),
            .searching(query: "冰岛 2026 人口"),
            .searchResults([first, second]),
            .citations([Citation(sources: [second, first], anchor: .afterText("人口约 39 万"))]),
            .searchCount(2),
        ]))
    }
}

@Suite struct WebSearchPriceTests {
    @Test func addsSearchCostInItsOwnCurrency() throws {
        let table = try PriceTable(json: Data(#"""
        {"updated":"x","providers":[
          {"name":"A","currency":"USD","webSearchPer1000":10,"models":[
            {"ids":["m1"],"input":2,"output":10},
            {"ids":["m2"],"input":2,"output":10,"webSearchPer1000":25}
          ]},
          {"name":"B","currency":"CNY","models":[{"ids":["m3"],"input":2,"output":8}]}
        ]}
        """#.utf8))
        let m1 = try #require(table.price(for: "m1"))
        #expect(m1.webSearchPer1000 == 10)
        #expect(table.price(for: "m2")?.webSearchPer1000 == 25)
        #expect(table.price(for: "m3")?.webSearchPer1000 == nil)
        // 只算搜索：3 次 × $10 / 1000 × 7.2 = ¥0.216
        #expect(abs(m1.costCNY(inputTokens: 0, outputTokens: 0, webSearches: 3, usdToCNY: 7.2) - 0.216) < 1e-9)
        // 手动填的人民币 token 单价，搜索费仍按美元换算。
        let custom = ModelPrice(input: 1, output: 1, currency: .cny, webSearchPer1000: 10, webSearchCurrency: .usd)
        #expect(abs(custom.costCNY(inputTokens: 1_000_000, outputTokens: 0, webSearches: 1, usdToCNY: 7.2) - 1.072) < 1e-9)
    }

    @Test func builtInTableHasSearchPrices() {
        #expect(PriceTable.builtIn.price(for: "claude-sonnet-5-5")?.webSearchPer1000 == 10)
        #expect(PriceTable.builtIn.price(for: "deepseek-flash")?.webSearchPer1000 == 0)
    }
}
