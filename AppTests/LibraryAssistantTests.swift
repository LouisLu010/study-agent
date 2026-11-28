import Foundation
import StudyKit
import SwiftData
import Testing
@testable import StudyAgent

private final class LibraryAssistantService: ChatService, @unchecked Sendable {
    enum Reply: Sendable {
        case events([ChatStreamEvent])
        case failure(ChatServiceError)
        case hold
    }

    private let lock = NSLock()
    private var captured: [ChatRequest] = []
    private var held: [AsyncThrowingStream<ChatStreamEvent, any Error>.Continuation] = []
    private let reply: @Sendable (ChatRequest, Int) -> Reply

    init(_ reply: @escaping @Sendable (ChatRequest, Int) -> Reply) {
        self.reply = reply
    }

    var requests: [ChatRequest] {
        lock.lock()
        defer { lock.unlock() }
        return captured
    }

    func streamChat(_ request: ChatRequest) -> AsyncThrowingStream<ChatStreamEvent, any Error> {
        lock.lock()
        let index = captured.count
        captured.append(request)
        lock.unlock()
        let response = reply(request, index)
        return AsyncThrowingStream { continuation in
            switch response {
            case let .events(events):
                for event in events { continuation.yield(event) }
                continuation.finish()
            case let .failure(error): continuation.finish(throwing: error)
            case .hold:
                lock.lock()
                held.append(continuation)
                lock.unlock()
            }
        }
    }
}

private func libraryCall(_ name: String, _ input: JSONValue) -> ChatStreamEvent {
    .toolCall(ToolCall(id: UUID().uuidString, name: name, arguments: input.jsonString))
}

private func libraryRead(_ id: UUID) -> ChatStreamEvent {
    libraryCall("read_cards", ["ids": [.string(id.uuidString)]])
}

private func libraryUpdate(_ request: ChatRequest, id: UUID, content: String = "精简后的定义与必要条件。") -> ChatStreamEvent {
    let result = request.messages.last?.toolResults.first?.content ?? ""
    let revision = JSONValue.parse(result)?["cards"]?.arrayValue?.first?["revision"]?.stringValue ?? "missing"
    return libraryCall("update_cards", ["updates": [[
        "id": .string(id.uuidString), "revision": .string(revision), "title": "导数定义", "content": .string(content),
        "example": "", "subject": "数学", "topic": "导数",
    ]]])
}

@MainActor
private final class LibraryAssistantFixture {
    let container: ModelContainer
    let context: ModelContext
    let model: ChatModel
    let card: ConceptCard

    init() throws {
        container = try ModelContainer(for: Schema(StudyAgentSchema.models), configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        context = ModelContext(container)
        model = ChatModel(modelID: "library-assistant-test", displayName: "测试模型")
        model.customInputPrice = 2
        model.customOutputPrice = 4
        context.insert(model)
        card = ConceptCard(title: "导数定义", content: "完整原文：定义与必要条件。")
        card.subject = .math
        card.topic = "导数"
        context.insert(card)
        try context.save()
    }

    func assistant(_ service: LibraryAssistantService) -> LibraryAssistant {
        let assistant = LibraryAssistant(service: service)
        assistant.selectedModel = model
        return assistant
    }
}

@MainActor
@Suite struct LibraryAssistantTests {
    @Test func localToolLoopSavesARealChangeAndUndoRestoresIt() async throws {
        let fixture = try LibraryAssistantFixture()
        let id = fixture.card.id
        let original = fixture.card.content
        let service = LibraryAssistantService { request, index in
            switch index {
            case 0: .events([libraryRead(id), .usage(input: 100, output: 20)])
            case 1: .events([libraryUpdate(request, id: id), .usage(input: 200, output: 40)])
            default: .events([.text("已精简导数定义，可撤销。"), .usage(input: 300, output: 10)])
            }
        }
        let assistant = fixture.assistant(service)

        await assistant.send("精简导数定义", context: fixture.context)?.value

        #expect(!assistant.isRunning && assistant.activity.isEmpty && assistant.errorMessage == nil)
        #expect(assistant.messages.count == 2 && assistant.messages.last?.text == "已精简导数定义，可撤销。")
        #expect(assistant.changes.count == 1)
        #expect(fixture.card.content == "精简后的定义与必要条件。")
        #expect(service.requests.count == 3)
        #expect(service.requests.allSatisfy { !$0.webSearch && $0.reasoningEffort == .low })
        #expect(service.requests.first?.tools == LibraryAssistantTools.tools)
        #expect(abs(assistant.costCNY - 0.00148) < 0.0000001)
        assistant.undoLast(context: fixture.context)
        #expect(assistant.changes.isEmpty)
        #expect(fixture.card.content == original)
        #expect(try ModelContext(fixture.container).fetch(FetchDescriptor<ConceptCard>()).first?.content == original)
        #expect(assistant.messages.last?.text.contains("已撤销") == true)
    }

    @Test func nextInstructionDropsToolTranscriptsAndRequiresAnewRead() async throws {
        let fixture = try LibraryAssistantFixture()
        let id = fixture.card.id
        let service = LibraryAssistantService { _, index in
            switch index {
            case 0: .events([libraryRead(id)])
            case 1: .events([.text("已读完，等待你的下一条要求。")])
            case 2: .events([libraryCall("update_cards", ["updates": [[
                "id": .string(id.uuidString), "revision": "old-revision", "title": "导数定义", "content": "不该写入",
                "example": "", "subject": "数学", "topic": "导数",
            ]]])])
            default: .events([.text("需要重新读取。")])
            }
        }
        let assistant = fixture.assistant(service)
        await assistant.send("先读取导数定义", context: fixture.context)?.value
        await assistant.send("再精简", context: fixture.context)?.value

        let secondInstruction = try #require(service.requests[safe: 2])
        #expect(secondInstruction.messages.allSatisfy { $0.toolCalls.isEmpty && $0.toolResults.isEmpty && $0.thinking.isEmpty })
        #expect(!secondInstruction.messages.contains { $0.text.contains("完整原文") })
        #expect(fixture.card.content == "完整原文：定义与必要条件。")
        #expect(assistant.changes.isEmpty)
        let result = try #require(service.requests.last?.messages.last?.toolResults.first)
        #expect(JSONValue.parse(result.content)?["error"] != nil)
    }

    @Test func historyIsShortAndKeepsTheCurrentInstructionIntact() async throws {
        let fixture = try LibraryAssistantFixture()
        let service = LibraryAssistantService { _, _ in .events([.text(String(repeating: "答", count: 3_000))]) }
        let assistant = fixture.assistant(service)
        for index in 0..<7 {
            await assistant.send("第 \(index) 次提问：" + String(repeating: "问", count: 3_000), context: fixture.context)?.value
        }

        let last = try #require(service.requests.last)
        #expect(last.messages.count <= LibraryAssistant.historyLimit)
        #expect(last.messages.first?.role == .user && last.messages.last?.role == .user)
        #expect(last.messages.dropLast().allSatisfy { $0.text.count <= LibraryAssistant.historyTextLimit })
        #expect(last.messages.last?.text.count == 3_008)
        #expect(!last.messages.contains { $0.text.hasPrefix("第 0 次提问") })
        #expect(assistant.messages.count == 14)
    }

    @Test func failedRequestRetainsSavedChangesForUndo() async throws {
        let fixture = try LibraryAssistantFixture()
        let id = fixture.card.id
        let service = LibraryAssistantService { request, index in
            switch index {
            case 0: .events([libraryRead(id)])
            case 1: .events([libraryUpdate(request, id: id)])
            default: .failure(.server(message: "测试服务中断"))
            }
        }
        let assistant = fixture.assistant(service)
        await assistant.send("精简知识卡", context: fixture.context)?.value

        #expect(assistant.errorMessage?.contains("测试服务中断") == true)
        #expect(assistant.changes.count == 1)
        #expect(assistant.messages.last?.text.contains("已保存 1 项操作") == true)
        assistant.undoLast(context: fixture.context)
        #expect(fixture.card.content == "完整原文：定义与必要条件。")
        #expect(assistant.errorMessage == nil && assistant.changes.isEmpty)
    }

    @Test func textFromSeparateToolTurnsIsSeparatedWithoutSplittingChunks() async throws {
        let fixture = try LibraryAssistantFixture()
        let id = fixture.card.id
        let service = LibraryAssistantService { _, index in
            switch index {
            case 0: .events([.text("先读取知识卡。"), libraryRead(id)])
            case 1: .events([
                .text("已读完，"), .text("继续查看目录。"),
                libraryCall("list_cards", ["query": "", "subject": "", "offset": 0, "limit": 1]),
            ])
            default: .failure(.server(message: "测试服务中断"))
            }
        }
        let assistant = fixture.assistant(service)

        await assistant.send("查看知识卡", context: fixture.context)?.value

        #expect(assistant.messages.last?.text.hasPrefix("先读取知识卡。\n\n已读完，继续查看目录。") == true)
    }

    @Test func stopPreventsMoreRequestsAndPreservesSavedChanges() async throws {
        let fixture = try LibraryAssistantFixture()
        let id = fixture.card.id
        let service = LibraryAssistantService { request, index in
            switch index {
            case 0: .events([libraryRead(id)])
            case 1: .events([libraryUpdate(request, id: id)])
            default: .hold
            }
        }
        let assistant = fixture.assistant(service)
        let task = try #require(assistant.send("精简知识卡", context: fixture.context))
        for _ in 0..<200 where service.requests.count < 3 {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(service.requests.count == 3 && assistant.changes.count == 1)
        #expect(assistant.send("另一条指令", context: fixture.context) == nil)
        assistant.undoLast(context: fixture.context)
        #expect(assistant.changes.count == 1)
        assistant.stop()
        await task.value

        #expect(!assistant.isRunning && assistant.errorMessage == nil)
        #expect(assistant.messages.count == 2 && assistant.messages.last?.text.contains("已停止") == true)
        #expect(assistant.changes.count == 1 && service.requests.count == 3)
        assistant.undoLast(context: fixture.context)
        #expect(fixture.card.content == "完整原文：定义与必要条件。")
    }

    @Test func undoConflictPreservesTheUserEditAndTheChangeRecord() async throws {
        let fixture = try LibraryAssistantFixture()
        let id = fixture.card.id
        let service = LibraryAssistantService { request, index in
            switch index {
            case 0: .events([libraryRead(id)])
            case 1: .events([libraryUpdate(request, id: id)])
            default: .events([.text("已完成。")])
            }
        }
        let assistant = fixture.assistant(service)
        await assistant.send("精简", context: fixture.context)?.value
        fixture.card.content = "用户在助手完成后再次编辑。"
        try fixture.context.save()

        assistant.undoLast(context: fixture.context)

        #expect(fixture.card.content == "用户在助手完成后再次编辑。")
        #expect(assistant.changes.count == 1 && assistant.errorMessage != nil)
    }

    @Test func unsupportedToolsUseTheLibraryAssistantError() async throws {
        let fixture = try LibraryAssistantFixture()
        let service = LibraryAssistantService { _, _ in .failure(.http(status: 400, message: "tools are unsupported")) }
        let assistant = fixture.assistant(service)
        await assistant.send("整理资料", context: fixture.context)?.value

        #expect(assistant.errorMessage?.contains("资料助手") == true)
        #expect(assistant.errorMessage?.contains("汇编") == false)
        #expect(!assistant.isRunning && assistant.changes.isEmpty)
    }

    @Test func blankMessagesAndMissingModelsNeverCallTheService() throws {
        let fixture = try LibraryAssistantFixture()
        let service = LibraryAssistantService { _, _ in .events([.text("不应调用")]) }
        let assistant = LibraryAssistant(service: service)
        #expect(assistant.send(" \n ", context: fixture.context) == nil)
        fixture.context.delete(fixture.model)
        try fixture.context.save()
        #expect(assistant.send("整理", context: fixture.context) == nil)
        #expect(assistant.errorMessage != nil && assistant.messages.isEmpty && service.requests.isEmpty)
        assistant.stop()
        assistant.undoLast(context: fixture.context)
        #expect(!assistant.isRunning)
    }

    @Test func defaultModelAndScopeAreUsedForAnEmptyAnswer() async throws {
        let fixture = try LibraryAssistantFixture()
        let service = LibraryAssistantService { _, _ in .events([]) }
        let assistant = LibraryAssistant(service: service)

        await assistant.send("查看资料", context: fixture.context, scopeDescription: "数学资料")?.value

        #expect(assistant.selectedModel?.id == fixture.model.id)
        #expect(service.requests.first?.model == fixture.model.modelID)
        #expect(service.requests.first?.systemPrompt?.contains("当前范围：数学资料") == true)
        #expect(assistant.messages.last?.text == "本轮没有修改资料。")
        #expect(assistant.costCNY == 0 && assistant.errorMessage == nil)
    }

    @Test func toolLimitStopsAServiceThatKeepsListing() async throws {
        let fixture = try LibraryAssistantFixture()
        let service = LibraryAssistantService { _, _ in
            .events([libraryCall("list_cards", ["query": "", "subject": "", "offset": 0, "limit": 1])])
        }
        let assistant = fixture.assistant(service)

        await assistant.send("查看资料", context: fixture.context)?.value

        #expect(service.requests.count == LibraryAssistantTools.maxCalls)
        #expect(!assistant.isRunning && assistant.changes.isEmpty)
        #expect(assistant.messages.last?.text.contains("达到操作上限") == true)
    }

    @Test func excessiveOutputStopsBeforeAnyToolWrites() async throws {
        let fixture = try LibraryAssistantFixture()
        let id = fixture.card.id
        let outputLimit = LibraryAssistant.outputLimit
        let service = LibraryAssistantService { _, _ in
            .events([.reasoning(String(repeating: "思", count: outputLimit + 1)), libraryRead(id)])
        }
        let assistant = fixture.assistant(service)
        await assistant.send("整理", context: fixture.context)?.value

        #expect(!assistant.isRunning && assistant.errorMessage == nil && assistant.changes.isEmpty)
        #expect(service.requests.count == 1)
        #expect(assistant.messages.last?.text.contains("输出较长") == true)
        #expect((assistant.messages.last?.text.count ?? 0) < 100)
    }

    @Test func repeatedLargeReadsStopWithoutSendingUnboundedContext() async throws {
        let fixture = try LibraryAssistantFixture()
        let id = fixture.card.id
        fixture.card.content = String(repeating: "a", count: 110_000)
        try fixture.context.save()
        let service = LibraryAssistantService { _, _ in .events([libraryRead(id)]) }
        let assistant = fixture.assistant(service)
        await assistant.send("读取资料", context: fixture.context)?.value

        #expect(service.requests.count == 3)
        #expect(assistant.messages.last?.text.contains("读取的资料较多") == true)
        #expect(assistant.changes.isEmpty && assistant.errorMessage == nil && !assistant.isRunning)
    }
}
