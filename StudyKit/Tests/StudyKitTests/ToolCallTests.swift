import Foundation
import Testing
@testable import StudyKit

private func body(_ request: URLRequest) throws -> [String: Any] {
    let data = try #require(request.httpBody)
    return try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
}

private let fetchTool = ToolDefinition(
    name: "fetch_question",
    description: "取一道题",
    parameters: ["type": "object", "properties": ["number": ["type": "string"]], "required": ["number"]]
)

/// 一轮工具调用之后的对话：用户问 → 模型思考并调用工具 → 工具结果。
private func conversation(thinking: [ThinkingBlock], callID: String = "call_1", signature: String? = nil) -> ChatRequest {
    ChatRequest(
        model: "m",
        systemPrompt: "规则",
        messages: [
            ChatMessage(role: .user, text: "开始吧"),
            ChatMessage(
                role: .assistant, text: "先取第 17 题",
                toolCalls: [ToolCall(id: callID, name: "fetch_question", arguments: #"{"number":"17"}"#, signature: signature)],
                thinking: thinking
            ),
            ChatMessage(role: .user, text: "", toolResults: [ToolResult(callID: callID, name: "fetch_question", content: #"{"status":"complete"}"#)]),
        ],
        reasoningEffort: .high,
        tools: [fetchTool]
    )
}

@Suite struct JSONValueTests {
    @Test func roundTripsAndReadsLoosely() throws {
        let value = try #require(JSONValue.parse(#"{"a":[1,2.5,"x",true,null],"n":17}"#))
        #expect(value["n"]?.stringValue == "17")
        #expect(value["a"]?.arrayValue?.count == 5)
        #expect(value["a"]?.arrayValue?[3].boolValue == true)
        #expect(value.jsonString == #"{"a":[1,2.5,"x",true,null],"n":17}"#)
        #expect(JSONValue.parse("不是 JSON") == nil)
        #expect(JSONValue.string("false").boolValue == false)
    }
}

@Suite struct OpenAIToolCallTests {
    let service = OpenAICompatibleService(baseURL: URL(string: "https://api.deepseek.com")!, apiKey: "k")

    @Test func encodesToolsCallsResultsAndReasoning() throws {
        let json = try body(service.makeURLRequest(for: conversation(thinking: [ThinkingBlock(text: "要先搜索")])))
        let tools = try #require(json["tools"] as? [[String: Any]])
        #expect(tools.count == 1)
        #expect(tools[0]["type"] as? String == "function")
        let function = try #require(tools[0]["function"] as? [String: Any])
        #expect(function["name"] as? String == "fetch_question")
        #expect((function["parameters"] as? [String: Any])?["type"] as? String == "object")

        let messages = try #require(json["messages"] as? [[String: Any]])
        #expect(messages.map { $0["role"] as? String } == ["system", "user", "assistant", "tool"])
        let assistant = messages[2]
        #expect(assistant["reasoning_content"] as? String == "要先搜索")
        let calls = try #require(assistant["tool_calls"] as? [[String: Any]])
        #expect(calls[0]["id"] as? String == "call_1")
        #expect((calls[0]["function"] as? [String: Any])?["arguments"] as? String == #"{"number":"17"}"#)
        #expect(messages[3]["tool_call_id"] as? String == "call_1")
        #expect(messages[3]["content"] as? String == #"{"status":"complete"}"#)
    }

    @Test func plainRequestsHaveNoToolFields() throws {
        let json = try body(service.makeURLRequest(for: ChatRequest(model: "m", messages: [ChatMessage(role: .user, text: "q")])))
        #expect(json["tools"] == nil)
        let messages = try #require(json["messages"] as? [[String: Any]])
        #expect(messages[0]["tool_calls"] == nil)
        #expect(messages[0]["reasoning_content"] == nil)
    }

    @Test func assemblesStreamedToolCalls() throws {
        let decoder = OpenAICompatibleService.StreamDecoder()
        var events: [ChatStreamEvent] = []
        func feed(_ data: String) throws {
            if case let .events(new) = try decoder.decode(data) { events += new }
        }
        try feed(#"{"choices":[{"delta":{"reasoning_content":"想一想"}}]}"#)
        try feed(#"{"choices":[{"delta":{"tool_calls":[{"index":0,"id":"call_a","type":"function","function":{"name":"search_web","arguments":""}}]}}]}"#)
        try feed(#"{"choices":[{"delta":{"tool_calls":[{"index":0,"function":{"arguments":"{\"query\":"}}]}}]}"#)
        try feed(#"{"choices":[{"delta":{"tool_calls":[{"index":1,"id":"call_b","function":{"name":"read_page","arguments":"{}"}}]}}]}"#)
        try feed(#"{"choices":[{"delta":{"tool_calls":[{"index":0,"function":{"arguments":"\"北京卷\"}"}}]}}]}"#)
        #expect(!events.contains { if case .toolCall = $0 { true } else { false } })
        try feed(#"{"choices":[{"delta":{},"finish_reason":"tool_calls"}]}"#)
        #expect(events == [
            .reasoning("想一想"),
            .toolCall(ToolCall(id: "call_a", name: "search_web", arguments: #"{"query":"北京卷"}"#)),
            .toolCall(ToolCall(id: "call_b", name: "read_page", arguments: "{}")),
        ])
        #expect(try decoder.finish().isEmpty)
    }

    @Test func flushesCallsWhenStreamEndsWithoutFinishReason() throws {
        let decoder = OpenAICompatibleService.StreamDecoder()
        _ = try decoder.decode(#"{"choices":[{"delta":{"tool_calls":[{"index":0,"function":{"name":"finish_paper","arguments":"{}"}}]}}]}"#)
        let events = try decoder.finish()
        guard case let .toolCall(call) = events.first else { Issue.record("没有工具调用"); return }
        #expect(call.name == "finish_paper")
        #expect(call.id.hasPrefix(ToolCall.localIDPrefix))
    }
}

@Suite struct AnthropicToolCallTests {
    let service = AnthropicService(baseURL: URL(string: "https://api.anthropic.com/v1")!, apiKey: "k")

    @Test func encodesToolsAndBlocksInOrder() throws {
        let request = conversation(thinking: [ThinkingBlock(text: "要先搜索", signature: "sig"), ThinkingBlock(text: "", redactedData: "xyz")])
        let json = try body(service.makeURLRequest(for: request))
        let tools = try #require(json["tools"] as? [[String: Any]])
        #expect(tools[0]["name"] as? String == "fetch_question")
        #expect((tools[0]["input_schema"] as? [String: Any])?["type"] as? String == "object")
        #expect(tools[0]["type"] == nil)

        let messages = try #require(json["messages"] as? [[String: Any]])
        #expect(messages.map { $0["role"] as? String } == ["user", "assistant", "user"])
        let assistant = try #require(messages[1]["content"] as? [[String: Any]])
        #expect(assistant.map { $0["type"] as? String } == ["thinking", "redacted_thinking", "text", "tool_use"])
        #expect(assistant[0]["signature"] as? String == "sig")
        #expect(assistant[1]["data"] as? String == "xyz")
        #expect((assistant[3]["input"] as? [String: Any])?["number"] as? String == "17")
        let results = try #require(messages[2]["content"] as? [[String: Any]])
        #expect(results.map { $0["type"] as? String } == ["tool_result"])
        #expect(results[0]["tool_use_id"] as? String == "call_1")
    }

    @Test func toolResultsComeBeforeTextWhenMerged() throws {
        var request = conversation(thinking: [])
        request.messages.append(ChatMessage(role: .user, text: "继续"))
        let json = try body(service.makeURLRequest(for: request))
        let messages = try #require(json["messages"] as? [[String: Any]])
        let last = try #require(messages.last?["content"] as? [[String: Any]])
        #expect(last.map { $0["type"] as? String } == ["tool_result", "text"])
    }

    @Test func decodesToolUseAndSignedThinking() throws {
        let decoder = AnthropicService.StreamDecoder()
        var events: [ChatStreamEvent] = []
        for line in [
            #"{"type":"content_block_start","index":0,"content_block":{"type":"thinking","thinking":"","signature":""}}"#,
            #"{"type":"content_block_delta","index":0,"delta":{"type":"thinking_delta","thinking":"先搜"}}"#,
            #"{"type":"content_block_delta","index":0,"delta":{"type":"signature_delta","signature":"abc"}}"#,
            #"{"type":"content_block_stop","index":0}"#,
            #"{"type":"content_block_start","index":1,"content_block":{"type":"tool_use","id":"toolu_1","name":"search_web","input":{}}}"#,
            #"{"type":"content_block_delta","index":1,"delta":{"type":"input_json_delta","partial_json":"{\"query\": \"2025"}}"#,
            #"{"type":"content_block_delta","index":1,"delta":{"type":"input_json_delta","partial_json":" 北京卷\"}"}}"#,
            #"{"type":"content_block_stop","index":1}"#,
        ] {
            if case let .events(new) = try decoder.decode(line) { events += new }
        }
        #expect(events == [
            .reasoning("先搜"),
            .thinkingBlock(ThinkingBlock(text: "先搜", signature: "abc")),
            .toolCall(ToolCall(id: "toolu_1", name: "search_web", arguments: #"{"query": "2025 北京卷"}"#)),
        ])
    }
}

@Suite struct GeminiToolCallTests {
    let service = GeminiService(baseURL: URL(string: "https://generativelanguage.googleapis.com/v1beta")!, apiKey: "k")

    @Test func encodesDeclarationsCallsAndResponses() throws {
        let json = try body(service.makeURLRequest(for: conversation(thinking: [], callID: "fc_1", signature: "sig1")))
        let tools = try #require(json["tools"] as? [[String: Any]])
        let declarations = try #require(tools[0]["functionDeclarations"] as? [[String: Any]])
        #expect(declarations[0]["name"] as? String == "fetch_question")

        let contents = try #require(json["contents"] as? [[String: Any]])
        #expect(contents.map { $0["role"] as? String } == ["user", "model", "user"])
        let modelParts = try #require(contents[1]["parts"] as? [[String: Any]])
        #expect(modelParts.count == 2)
        let call = try #require(modelParts[1]["functionCall"] as? [String: Any])
        #expect(call["id"] as? String == "fc_1")
        #expect((call["args"] as? [String: Any])?["number"] as? String == "17")
        #expect(modelParts[1]["thoughtSignature"] as? String == "sig1")
        let userParts = try #require(contents[2]["parts"] as? [[String: Any]])
        let response = try #require(userParts[0]["functionResponse"] as? [String: Any])
        #expect(response["name"] as? String == "fetch_question")
        #expect(response["id"] as? String == "fc_1")
        #expect((response["response"] as? [String: Any])?["status"] as? String == "complete")
    }

    @Test func omitsMadeUpIDs() throws {
        let id = ToolCall.localIDPrefix + "1"
        let json = try body(service.makeURLRequest(for: conversation(thinking: [], callID: id)))
        let contents = try #require(json["contents"] as? [[String: Any]])
        let call = try #require((contents[1]["parts"] as? [[String: Any]])?[1]["functionCall"] as? [String: Any])
        #expect(call["id"] == nil)
        let response = try #require((contents[2]["parts"] as? [[String: Any]])?[0]["functionResponse"] as? [String: Any])
        #expect(response["id"] == nil)
    }

    @Test func decodesFunctionCallsWithSignatures() throws {
        let payload = try GeminiService.decodeStreamData(#"""
        {"candidates":[{"content":{"parts":[{"text":"想","thought":true},{"functionCall":{"name":"search_web","args":{"query":"北京卷"},"id":"fc_9"},"thoughtSignature":"s1"}]}}]}
        """#)
        guard case let .events(events) = payload else { Issue.record("没有事件"); return }
        #expect(events == [
            .reasoning("想"),
            .toolCall(ToolCall(id: "fc_9", name: "search_web", arguments: #"{"query":"北京卷"}"#, signature: "s1")),
        ])
    }
}

/// 按顺序给出几轮回答的假服务。
private final class ScriptedService: ChatService, @unchecked Sendable {
    var turns: [[ChatStreamEvent]]
    var error: (any Error)?
    private(set) var requests: [ChatRequest] = []

    init(_ turns: [[ChatStreamEvent]], error: (any Error)? = nil) {
        self.turns = turns
        self.error = error
    }

    func streamChat(_ request: ChatRequest) -> AsyncThrowingStream<ChatStreamEvent, any Error> {
        requests.append(request)
        let events = turns.isEmpty ? [] : turns.removeFirst()
        let error = self.error
        return AsyncThrowingStream { continuation in
            if let error { continuation.finish(throwing: error); return }
            events.forEach { continuation.yield($0) }
            continuation.finish()
        }
    }
}

private func call(_ id: String, _ name: String, _ arguments: String = "{}") -> ChatStreamEvent {
    .toolCall(ToolCall(id: id, name: name, arguments: arguments))
}

@Suite struct ToolLoopTests {
    let request = ChatRequest(model: "m", messages: [ChatMessage(role: .user, text: "开始")], tools: [fetchTool])

    @Test func runsToolsUntilOneSaysStop() async throws {
        let service = ScriptedService([
            [.reasoning("想"), .text("先搜"), call("a", "search_web"), .usage(input: 100, output: 10), .cachedInput(60)],
            [call("b", "fetch_question", #"{"number":"17"}"#), call("c", "finish_paper")],
        ])
        let executed = Recorder()
        let usages = Recorder()
        let result = try await ToolLoop(maxCalls: 10).run(
            service: service, request: request,
            onUsage: { await usages.add("\($0.input ?? 0)/\($0.cachedInput)/\($0.output ?? 0)") }
        ) { call in
            await executed.add(call.name)
            return ToolLoop.Outcome(["ok": true], stop: call.name == "finish_paper")
        }
        #expect(result.ending == .stopped)
        #expect(result.calls == 3)
        #expect(await executed.items == ["search_web", "fetch_question", "finish_paper"])
        #expect(await usages.items == ["100/60/10", "0/0/0"])
        // 第二次请求带着第一轮的思考、调用和结果。
        let second = service.requests[1].messages
        #expect(second.count == 3)
        #expect(second[1].thinking == [ThinkingBlock(text: "想")])
        #expect(second[1].toolCalls.map(\.id) == ["a"])
        #expect(second[2].toolResults == [ToolResult(callID: "a", name: "search_web", content: #"{"ok":true}"#)])
    }

    @Test func stopsAtTheLimitAndStillAnswersEveryCall() async throws {
        let service = ScriptedService([[call("a", "search_web"), call("b", "search_web"), call("c", "search_web")]])
        let result = try await ToolLoop(maxCalls: 2).run(service: service, request: request) { _ in ToolLoop.Outcome(["ok": true]) }
        #expect(result.ending == .limitReached)
        #expect(result.calls == 2)
        #expect(result.messages.last?.toolResults.count == 3)
        #expect(result.messages.last?.toolResults.last?.content.contains("没有执行") == true)
    }

    @Test func nudgesOnceThenReturnsTheAnswer() async throws {
        let service = ScriptedService([[.text("我觉得没有")], [.text("确实没有")]])
        let result = try await ToolLoop(maxCalls: 5, nudge: "请调用 finish_paper").run(service: service, request: request) { _ in
            ToolLoop.Outcome(["ok": true])
        }
        #expect(result.ending == .answered("确实没有"))
        #expect(service.requests[1].messages.last?.text == "请调用 finish_paper")
    }

    @Test func toolErrorsGoBackToTheModel() async throws {
        struct Broken: Error, LocalizedError { var errorDescription: String? { "网页打不开" } }
        let service = ScriptedService([[call("a", "read_page")], [.text("好")]])
        let result = try await ToolLoop(maxCalls: 5).run(service: service, request: request) { _ in throw Broken() }
        #expect(result.ending == .answered("好"))
        #expect(service.requests[1].messages.last?.toolResults.first?.content == #"{"error":"网页打不开"}"#)
    }

    @Test func reportsModelsWithoutToolSupport() async {
        let service = ScriptedService([], error: ChatServiceError.http(status: 400, message: "This model does not support tools"))
        await #expect(throws: ToolLoopError.toolsUnsupported) {
            try await ToolLoop(maxCalls: 5).run(service: service, request: request) { _ in ToolLoop.Outcome(["ok": true]) }
        }
        let other = ScriptedService([], error: ChatServiceError.http(status: 401, message: "bad key"))
        await #expect(throws: ChatServiceError.http(status: 401, message: "bad key")) {
            try await ToolLoop(maxCalls: 5).run(service: other, request: request) { _ in ToolLoop.Outcome(["ok": true]) }
        }
    }

    @Test func rejectsTheWholeTurnBeforeExecutingInvalidArguments() async {
        let service = ScriptedService([[call("a", "search_web"), call("b", "fetch_question", "[]")]])
        let executed = Recorder()
        await #expect(throws: ChatServiceError.invalidToolArguments(name: "fetch_question")) {
            try await ToolLoop(maxCalls: 5).run(service: service, request: request) { call in
                await executed.add(call.name)
                return ToolLoop.Outcome(["ok": true])
            }
        }
        #expect(await executed.items.isEmpty)
    }

    @Test func cancellationDuringEventDeliveryDoesNotExecuteTools() async {
        let service = ScriptedService([[call("a", "finish_paper")]])
        let executed = Recorder()
        let task = Task {
            try await ToolLoop(maxCalls: 5).run(
                service: service, request: request,
                onEvent: { _ in withUnsafeCurrentTask { $0?.cancel() } }
            ) { call in
                await executed.add(call.name)
                return ToolLoop.Outcome(["ok": true], stop: true)
            }
        }
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(await executed.items.isEmpty)
    }

    @Test func cancellationWithNormalStreamEOFCannotReturnSuccess() async {
        struct CancellingService: ChatService {
            func streamChat(_ request: ChatRequest) -> AsyncThrowingStream<ChatStreamEvent, any Error> {
                withUnsafeCurrentTask { $0?.cancel() }
                return AsyncThrowingStream { $0.finish() }
            }
        }
        let task = Task {
            try await ToolLoop(maxCalls: 5).run(service: CancellingService(), request: request) { _ in
                ToolLoop.Outcome(["ok": true], stop: true)
            }
        }
        await #expect(throws: CancellationError.self) { try await task.value }
    }

    @Test func cancellationDuringUsageDeliveryDoesNotExecuteTools() async {
        let service = ScriptedService([[call("a", "finish_paper")]])
        let executed = Recorder()
        let task = Task {
            try await ToolLoop(maxCalls: 5).run(
                service: service, request: request,
                onUsage: { _ in withUnsafeCurrentTask { $0?.cancel() } }
            ) { call in
                await executed.add(call.name)
                return ToolLoop.Outcome(["ok": true], stop: true)
            }
        }
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(await executed.items.isEmpty)
    }

    @Test func cancellationInsideToolCannotReturnSuccessOrExecuteTheNextTool() async {
        let service = ScriptedService([[call("a", "read_page"), call("b", "finish_paper")]])
        let executed = Recorder()
        let task = Task {
            try await ToolLoop(maxCalls: 5).run(service: service, request: request) { call in
                await executed.add(call.name)
                withUnsafeCurrentTask { $0?.cancel() }
                return ToolLoop.Outcome(["ok": true], stop: true)
            }
        }
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(await executed.items == ["read_page"])
    }
}

private actor Recorder {
    var items: [String] = []
    func add(_ item: String) { items.append(item) }
}

@Suite struct CompilationToolsTests {
    @Test func checksSubmittedPapers() throws {
        let good: JSONValue = [
            "title": "近三年高考有机大题", "subject": "化学",
            "papers": [
                ["title": "2025年高考化学北京卷", "short": "北京卷", "year": "2025"],
                ["title": "2025年高考化学北京卷", "short": "北京卷", "year": "2025"],
                ["title": "2024年新课标卷（理综）", "year": 2024],
            ],
        ]
        let list = try CompilationTools.parsePapers(good, fallbackTitle: "x").get()
        #expect(list.title == "近三年高考有机大题")
        #expect(list.subject == .chemistry)
        #expect(list.papers.map(\.title) == ["2025年高考化学北京卷", "2024年新课标卷（理综）"])
        #expect(list.papers[1].year == "2024")

        let badYear: JSONValue = ["title": "t", "subject": "化学", "papers": [["title": "某卷", "year": "近年"]]]
        #expect(throws: CompilationTools.ArgumentError.self) { try CompilationTools.parsePapers(badYear, fallbackTitle: "x").get() }
        let empty: JSONValue = ["title": "t", "subject": "化学", "papers": []]
        #expect(throws: CompilationTools.ArgumentError.self) { try CompilationTools.parsePapers(empty, fallbackTitle: "x").get() }
    }

    @Test func checksArrangement() throws {
        let ids = ["Q1", "Q2", "Q3"]
        let grouped: JSONValue = ["title": "有机大题", "groups": [
            ["name": "合成路线", "items": ["q3", "Q1"]],
        ]]
        let arrangement = try CompilationTools.parseArrangement(grouped, ids: ids, fallbackTitle: "x").get()
        #expect(arrangement.order == ["Q3", "Q1", "Q2"])
        #expect(arrangement.groups == ["Q3": "合成路线", "Q1": "合成路线"])

        let unknown: JSONValue = ["title": "t", "order": ["Q1", "Q9"]]
        #expect(throws: CompilationTools.ArgumentError.self) { try CompilationTools.parseArrangement(unknown, ids: ids, fallbackTitle: "x").get() }
        let repeated: JSONValue = ["title": "t", "order": ["Q1", "Q1"]]
        #expect(throws: CompilationTools.ArgumentError.self) { try CompilationTools.parseArrangement(repeated, ids: ids, fallbackTitle: "x").get() }
    }

    @Test func endsPapersThatStopMakingProgress() {
        var progress = PaperProgress()
        var ended: [Bool] = []
        ended.append(progress.record(host: "gaotu.cn"))
        for _ in 0..<7 { ended.append(progress.record(host: "gaotu.cn")) }
        ended.append(progress.record())
        #expect(ended == Array(repeating: false, count: 8) + [true])
        let resumed = progress.record(newQuestion: true)
        #expect(!resumed)
        #expect(progress.callsWithoutProgress == 0)
    }

    @Test func formatsQuestionsAndNumbers() {
        let id = UUID().uuidString
        #expect(CompilationTools.textForModel("如图![](sa-asset:\(id))和![](sa-image:1 \"w=1\")") == "如图[图1]和[图2]")
        #expect(CompilationTools.textForModel("一二三四五", limit: 3) == "一二三……")
        #expect(CompilationTools.sameNumber("18-20", "第18～20题"))
        #expect(!CompilationTools.sameNumber("17", "18"))
        #expect(CompilationTools.isBetter(.complete, than: .imagesMissing))
        #expect(!CompilationTools.isBetter(.imagesMissing, than: .complete))
        #expect(CompilationTools.FetchStatus.forHTTP(405) == .refused)
        #expect(CompilationTools.FetchStatus.forHTTP(500) == .failed)
    }

    @Test func readsSearchResults() {
        let api = CompilationTools.parseSearchAPI(Data(#"{"results":[{"title":"北京卷","url":"https://gaotu.cn/1","snippet":"第17题"},{"title":"无网址"}]}"#.utf8))
        #expect(api == [.init(title: "北京卷", url: "https://gaotu.cn/1", snippet: "第17题")])
        let reply = CompilationTools.parseSearchReply(#"结果：[{"title":"a","url":"https://a.cn","snippet":"s"}]"#, fallback: [])
        #expect(reply.map(\.url) == ["https://a.cn"])
        let fallback = CompilationTools.parseSearchReply("没按格式", fallback: [WebSource(url: "https://b.cn", title: "b"), WebSource(url: "https://b.cn", title: "b")])
        #expect(fallback.map(\.url) == ["https://b.cn"])
    }

    @Test func usesSearchAPIOnlyForOfficialDeepSeek() {
        #expect(CompilationTools.deepSeekToolsBase(kind: .openAICompatible, baseURL: "https://api.deepseek.com")?.absoluteString == "https://api.deepseek.com/v1/tools")
        #expect(CompilationTools.deepSeekToolsBase(kind: .openAICompatible, baseURL: "https://api.deepseek.com/v1") != nil)
        #expect(CompilationTools.deepSeekToolsBase(kind: .anthropic, baseURL: "https://api.deepseek.com/anthropic") == nil)
        #expect(CompilationTools.deepSeekToolsBase(kind: .openAICompatible, baseURL: "https://openrouter.ai/api/v1") == nil)
    }

    @Test func requestsDeclareOnlyAppTools() {
        let paper = PaperPlan(title: "2025年高考化学北京卷", year: "2025")
        let list = CompilationTools.listingRequest(model: "m", request: "近3年有机大题", reasoningEffort: nil)
        #expect(!list.webSearch)
        #expect(list.tools.map(\.name) == ["search_web", "read_page", "submit_papers"])
        let find = CompilationTools.paperRequest(
            model: "m", request: "有机大题", paper: paper,
            existing: [.init(number: "17", status: .complete), .init(number: "18", status: .imagesMissing)],
            onlyNumber: "18", reasoningEffort: .high
        )
        #expect(!find.webSearch)
        #expect(find.tools.map(\.name) == ["search_web", "read_page", "fetch_question", "remove_question", "finish_paper"])
        let task = find.messages.first?.text ?? ""
        #expect(task.contains("只找这份试卷的第 18 题"))
        #expect(task.contains("第 17 题（完整）"))
        #expect(!task.contains("第 18 题（"))
        let arrange = CompilationTools.arrangingRequest(
            model: "m", request: "r", title: "t", items: [.init(id: "Q1", label: "2025 · 北京卷 · 第 17 题", preview: "一种")], reasoningEffort: nil
        )
        #expect(arrange.tools.map(\.name) == ["arrange", "make_pdf"])
        #expect(arrange.messages.first?.text.contains("Q1　2025 · 北京卷 · 第 17 题") == true)
    }
}

@Suite struct PageTextTests {
    @Test func extractsReadableText() {
        let page = PageText.extract(html: """
        <html><head><title>2025 北京卷 &amp; 答案</title><script>var a = 1;</script></head>
        <body><div>17．一种受体<b>拮抗剂</b>的合成路线如下：</div><p><img src="a.png">（1）A 的名称</p>
        <table><tr><td>甲</td><td>乙</td></tr></table></body></html>
        """)
        #expect(page.title == "2025 北京卷 & 答案")
        #expect(page.text == "17．一种受体拮抗剂的合成路线如下：\n[图]（1）A 的名称\n甲 乙")
    }

    @Test func turnsFetchMarkdownIntoLocatableHTML() throws {
        let markdown = "# 2025 北京卷\n\n17. 一种受体拮抗剂的合成路线如下：![](https://x/1.png)\n\n（1）A 的名称是[链接](https://y)\n\n18. 下一题"
        #expect(PageText.fromMarkdown(markdown).contains("合成路线如下：[图]"))
        let html = PageText.html(fromMarkdown: markdown)
        let result = try QuestionExtractor.extract(
            html: html, baseURL: URL(string: "https://x")!, anchor: "一种受体拮抗剂的合成", lastAnchor: "A的名称"
        ).get()
        #expect(result.content.contains("一种受体拮抗剂"))
        #expect(result.imageURLs.isEmpty)
    }
}
