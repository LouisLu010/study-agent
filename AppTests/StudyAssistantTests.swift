import Foundation
import StudyKit
import SwiftData
import SwiftUI
import Testing
import XCTest
import WebKit
@testable import StudyAgent

private final class StudyAssistantService: ChatService, @unchecked Sendable {
    enum Response: Sendable { case events([ChatStreamEvent]), failure(ChatServiceError), hold }
    private let lock = NSLock()
    private var captured: [ChatRequest] = []
    private let respond: @Sendable (ChatRequest, Int) -> Response

    init(_ respond: @escaping @Sendable (ChatRequest, Int) -> Response) { self.respond = respond }

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
        let response = respond(request, index)
        return AsyncThrowingStream { continuation in
            switch response {
            case let .events(events):
                for event in events { continuation.yield(event) }
                continuation.finish()
            case let .failure(error): continuation.finish(throwing: error)
            case .hold: break
            }
        }
    }
}

private func studyRead(kind: StudyRecordKind, id: UUID, offset: Int = 0, limit: Int = 8_000) -> ToolCall {
    let input: JSONValue = [
        "kind": .string(kind.rawValue), "id": .string(id.uuidString), "offset": .number(Double(offset)), "limit": .number(Double(limit)),
    ]
    return ToolCall(id: UUID().uuidString, name: "read_study_record", arguments: input.jsonString)
}

private func studySearch(kind: String = "", query: String = "", subject: String = "", since: String = "", offset: Int = 0, limit: Int = 20) -> ToolCall {
    let input: JSONValue = [
        "kind": .string(kind), "query": .string(query), "subject": .string(subject), "since": .string(since),
        "offset": .number(Double(offset)), "limit": .number(Double(limit)),
    ]
    return ToolCall(id: UUID().uuidString, name: "search_study_records", arguments: input.jsonString)
}

@MainActor
private final class StudyAssistantFixture {
    let container: ModelContainer
    let context: ModelContext
    let conversation: Conversation
    let current: Conversation
    let mistake: Mistake
    let card: ConceptCard
    let compilation: Compilation
    let question: ExamQuestion
    let model: ChatModel

    init() throws {
        container = try ModelContainer(for: Schema(StudyAgentSchema.models), configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        context = ModelContext(container)
        let provider = Provider(name: "测试", kind: .openAICompatible, baseURL: "https://example.invalid/v1")
        context.insert(provider)
        model = ChatModel(modelID: "study-assistant-test")
        model.provider = provider
        model.customInputPrice = 2
        model.customOutputPrice = 4
        context.insert(model)
        conversation = Conversation(title: "以前的数学会话")
        context.insert(conversation)
        let message = Message(role: .user, content: "导数的符号与单调性", index: 0)
        context.insert(message)
        message.conversation = conversation
        current = Conversation(title: "当前学习助手")
        current.isStudyAssistant = true
        context.insert(current)
        current.model = model
        mistake = Mistake(kind: .quiz)
        mistake.subject = .math
        mistake.topic = "导数"
        mistake.questionJSON = #"{"question":"导数为什么为负？","answer":1}"#
        mistake.wrongAnswerJSON = #"{"choice":[0]}"#
        mistake.note = "忘记检查定义域"
        mistake.reviewCount = 2
        context.insert(mistake)
        card = ConceptCard(title: "单调性", content: "导数为负的区间内，函数严格递减。")
        card.subject = .math
        card.topic = "导数"
        card.example = "例如 f(x)=-x。"
        context.insert(card)
        compilation = Compilation(request: "导数原题")
        compilation.subject = .math
        context.insert(compilation)
        question = ExamQuestion(paperTitle: "测试数学试卷", year: "2026", number: "1", index: 0)
        question.content = "利用导数判断单调性。"
        question.answer = "检查导数的正负。"
        question.sourceURL = "https://example.invalid/paper/1"
        context.insert(question)
        question.compilation = compilation
        let date = Date(timeIntervalSince1970: 1_795_000_000)
        conversation.updatedAt = date
        card.updatedAt = date
        mistake.createdAt = date
        compilation.updatedAt = date
        question.createdAt = date
        try context.save()
    }

    func toolbox(references: [StudyReference] = [], hiddenIDs: @escaping @MainActor () -> Set<PersistentIdentifier> = { [] }) -> StudyAssistantToolbox {
        StudyAssistantToolbox(context: context, conversationID: current.id, references: references, hiddenIDs: hiddenIDs)
    }

    func reply() -> Message {
        let value = Message(role: .assistant, status: .streaming, index: 0)
        context.insert(value)
        value.conversation = current
        return value
    }

    func runner(_ reply: Message) -> StudyAssistantReply {
        StudyAssistantReply(reply: reply, context: context, conversationID: current.id, price: model.price(), rate: 1)
    }
}

@MainActor
@Suite struct StudyAssistantToolboxTests {
    @Test func searchesAllFiveKindsAndConversationBodiesWithStablePagination() async throws {
        let fixture = try StudyAssistantFixture()
        let toolbox = fixture.toolbox()
        let first = try await toolbox.execute(studySearch(query: "导数", limit: 2))
        let page = try #require(JSONValue.parse(first.content))
        #expect(page["total"]?.stringValue == "5")
        #expect(page["next_offset"]?.stringValue == "2")
        let second = try await toolbox.execute(studySearch(query: "导数", offset: 2, limit: 20))
        let rest = try #require(JSONValue.parse(second.content))
        let all = (page["records"]?.arrayValue ?? []) + (rest["records"]?.arrayValue ?? [])
        #expect(Set(all.compactMap { $0["kind"]?.stringValue }) == Set(StudyRecordKind.allCases.map(\.rawValue)))
        #expect(Set(all.compactMap { $0["id"]?.stringValue }).count == 5)
        #expect(rest["next_offset"] == .null)
        #expect(toolbox.references.isEmpty)
        let empty = try await toolbox.execute(studySearch(query: "不存在的主题"))
        #expect(JSONValue.parse(empty.content)?["total"]?.stringValue == "0")
    }

    @Test func filtersSubjectDateAndKindAndKeepsDatesHonest() async throws {
        let fixture = try StudyAssistantFixture()
        let toolbox = fixture.toolbox()
        let math = try await toolbox.execute(studySearch(kind: "mistake", query: "定义域", subject: "数学"))
        #expect(JSONValue.parse(math.content)?["total"]?.stringValue == "1")
        let chemistry = try await toolbox.execute(studySearch(subject: "化学"))
        #expect(JSONValue.parse(chemistry.content)?["total"]?.stringValue == "0")
        let future = try await toolbox.execute(studySearch(since: "2099-01-01T00:00:00Z"))
        #expect(JSONValue.parse(future.content)?["total"]?.stringValue == "0")
        let old = try await toolbox.execute(studySearch(kind: "conversation", subject: "数学", since: "2020-01-01T00:00:00Z"))
        #expect(JSONValue.parse(old.content)?["total"]?.stringValue == "1")
    }

    @Test func readsOriginalsAndPaginatesUnicodeWithoutDuplicatingReferences() async throws {
        let fixture = try StudyAssistantFixture()
        fixture.card.content = String(repeating: "前文", count: 200) + "定位词👨‍👩‍👧‍👦后文"
        let toolbox = fixture.toolbox()
        let search = try await toolbox.execute(studySearch(kind: "card", query: "定位词"))
        let offset = Int(try #require(JSONValue.parse(search.content)?["records"]?.arrayValue?.first?["read_offset"]?.stringValue))!
        #expect(offset > 0)
        let first = try await toolbox.execute(studyRead(kind: .card, id: fixture.card.id, offset: offset, limit: 10))
        let json = try #require(JSONValue.parse(first.content))
        #expect(json["citation"]?.stringValue == "[资料1]")
        let next = Int(try #require(json["next_offset"]?.stringValue))!
        _ = try await toolbox.execute(studyRead(kind: .card, id: fixture.card.id, offset: next))
        #expect(toolbox.references.count == 1)
        let mistake = try await toolbox.execute(studyRead(kind: .mistake, id: fixture.mistake.id))
        #expect(mistake.content.contains("choice") && mistake.content.contains("忘记检查定义域") && mistake.content.contains("测验判分"))
        let compilation = try await toolbox.execute(studyRead(kind: .compilation, id: fixture.compilation.id))
        #expect(compilation.content.contains(fixture.question.id.uuidString))
        let question = try await toolbox.execute(studyRead(kind: .question, id: fixture.question.id))
        #expect(question.content.contains(fixture.question.sourceURL) && question.content.contains(fixture.question.answer))
        #expect(toolbox.references.map(\.number) == [1, 2, 3, 4])
        let continued = fixture.toolbox(references: toolbox.references)
        _ = try await continued.execute(studyRead(kind: .conversation, id: fixture.conversation.id))
        #expect(continued.references.last?.number == 5)
    }

    @Test func rejectsMissingDeletedHiddenCurrentAndOrphanRecords() async throws {
        let fixture = try StudyAssistantFixture()
        let hidden = Set([fixture.card.persistentModelID, fixture.compilation.persistentModelID])
        let toolbox = fixture.toolbox(hiddenIDs: { hidden })
        for (kind, id) in [(StudyRecordKind.card, fixture.card.id), (.question, fixture.question.id),
                           (.compilation, fixture.compilation.id), (.conversation, fixture.current.id), (.mistake, UUID())] {
            await #expect(throws: StudyAssistantTools.ArgumentError.self) { try await toolbox.execute(studyRead(kind: kind, id: id)) }
        }
        let id = fixture.mistake.id
        fixture.context.delete(fixture.mistake)
        try fixture.context.save()
        await #expect(throws: StudyAssistantTools.ArgumentError.self) { try await toolbox.execute(studyRead(kind: .mistake, id: id)) }
        #expect(toolbox.references.isEmpty)
        let search = try await toolbox.execute(studySearch())
        #expect(JSONValue.parse(search.content)?["total"]?.stringValue == "1")
    }

    @Test func readingIsReadOnlyAndLimitsCombinedResultSize() async throws {
        let fixture = try StudyAssistantFixture()
        fixture.card.content = String(repeating: "汉", count: 10_000)
        try fixture.context.save()
        let toolbox = fixture.toolbox()
        var stopped = false
        for _ in 0..<20 {
            let result = try await toolbox.execute(studyRead(kind: .card, id: fixture.card.id))
            if result.stop { stopped = true; break }
        }
        #expect(stopped)
        #expect(fixture.card.content.count == 10_000)
        #expect(toolbox.references.count == 1)
        await #expect(throws: StudyAssistantTools.ArgumentError.self) {
            try await fixture.toolbox().execute(studyRead(kind: .card, id: fixture.card.id, offset: 1_000_000))
        }
        let stored = try #require(ModelContext(fixture.container).fetch(FetchDescriptor<ConceptCard>()).first)
        #expect(stored.content.count == 10_000)
    }
}

@MainActor
@Suite struct StudyAssistantReplyTests {
    @Test func readsRealSourceStreamsFinalAnswerAndAccumulatesEachRequestCost() async throws {
        let fixture = try StudyAssistantFixture()
        let id = fixture.card.id
        let service = StudyAssistantService { _, index in
            switch index {
            case 0: .events([.text("先查找。"), .toolCall(studySearch(query: "导数")), .usage(input: 100, output: 20)])
            case 1: .events([.toolCall(studyRead(kind: .card, id: id)), .usage(input: 200, output: 40)])
            default: .events([.reasoning("结合原文"), .text("函数递减 [资料1]。"), .usage(input: 300, output: 10), .cachedInput(20)])
            }
        }
        let reply = fixture.reply()
        let request = ChatRequest(model: fixture.model.modelID, messages: [ChatMessage(role: .user, text: "帮我复习导数")])
        #expect(try await fixture.runner(reply).run(service: service, request: request))
        #expect(reply.content == "函数递减 [资料1]。" && reply.reasoning == "结合原文")
        #expect(reply.studyReferences.first?.recordID == id)
        #expect(reply.inputTokens == 600 && reply.outputTokens == 70 && reply.cachedInputTokens == 20)
        #expect(abs((reply.costCNY ?? 0) - 0.00148) < 0.0000001)
        #expect(service.requests.count == 3 && service.requests.allSatisfy { !$0.webSearch && $0.tools == StudyAssistantTools.tools })
        #expect(service.requests.last?.messages.last?.toolResults.first?.content.contains(fixture.card.content) == true)
    }

    @Test func answersAfterMoreThanSixteenSearchesAndReads() async throws {
        let fixture = try StudyAssistantFixture()
        let id = fixture.card.id
        let count = 24
        let service = StudyAssistantService { _, index in
            if index == count { return .events([.text("函数递减 [资料1]。"), .usage(input: 100, output: 10)]) }
            let call = index.isMultiple(of: 2) ? studySearch(kind: "card") : studyRead(kind: .card, id: id)
            return .events([.toolCall(call), .usage(input: 100, output: 10)])
        }
        let reply = fixture.reply()
        let request = ChatRequest(model: "test", messages: [ChatMessage(role: .user, text: "查找")])
        #expect(try await fixture.runner(reply).run(service: service, request: request))
        #expect(service.requests.count == count + 1)
        #expect(reply.content == "函数递减 [资料1]。")
        #expect(reply.studyReferences.map(\.recordID) == [id])
        #expect(reply.inputTokens == 2_500 && reply.outputTokens == 250)
        #expect(abs((reply.costCNY ?? 0) - 0.006) < 0.0000001)
        let results = try #require(service.requests.last).messages.flatMap(\.toolResults)
        #expect(results.count == count)
        #expect(results.last?.content.contains(fixture.card.content) == true)
    }

    @Test func stopsOnOutputLimit() async throws {
        let fixture = try StudyAssistantFixture()
        let request = ChatRequest(model: "test", messages: [ChatMessage(role: .user, text: "查找")])
        let longReply = fixture.reply()
        let long = StudyAssistantService { _, _ in .events([.text(String(repeating: "字", count: StudyAssistantTools.maxOutputLength + 1))]) }
        #expect(try await !fixture.runner(longReply).run(service: long, request: request))
        #expect(longReply.content.count < 100 && longReply.content.contains("输出较长"))
    }

    @Test func stopsOnReadContentLimitAndPreservesReferences() async throws {
        let fixture = try StudyAssistantFixture()
        fixture.card.content = String(repeating: "字", count: 8_000)
        let id = fixture.card.id
        let service = StudyAssistantService { _, _ in .events([.toolCall(studyRead(kind: .card, id: id))]) }
        let reply = fixture.reply()
        let request = ChatRequest(model: "test", messages: [ChatMessage(role: .user, text: "阅读")])
        #expect(try await !fixture.runner(reply).run(service: service, request: request))
        #expect(reply.content.contains("读取内容已达到上限"))
        #expect(reply.studyReferences.map(\.recordID) == [id])
    }

    @Test(arguments: [1, 20])
    func cancelPreservesReadReferencesAndDoesNotContinueTools(reads: Int) async throws {
        let fixture = try StudyAssistantFixture()
        let id = fixture.card.id
        let service = StudyAssistantService { _, index in
            index < reads ? .events([.toolCall(studyRead(kind: .card, id: id))]) : .hold
        }
        let reply = fixture.reply()
        let runner = fixture.runner(reply)
        let task = Task { try await runner.run(service: service, request: ChatRequest(model: "test", messages: [ChatMessage(role: .user, text: "查找")])) }
        for _ in 0..<200 {
            if service.requests.count >= reads + 1 { break }
            try await Task.sleep(for: .milliseconds(5))
        }
        #expect(service.requests.count == reads + 1)
        task.cancel()
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(reply.studyReferences.first?.recordID == id)
        #expect(service.requests.count == reads + 1)
    }

    @Test func continuingKeepsPrefixAndRejectsEmptyAnswers() async throws {
        let fixture = try StudyAssistantFixture()
        let reply = fixture.reply()
        reply.content = "之前的内容"
        let reference = StudyReference(number: 1, kind: .card, recordID: fixture.card.id, title: "旧资料")
        reply.studyReferences = [reference]
        let service = StudyAssistantService { _, _ in .events([.text("接着讲。")]) }
        let request = ChatRequest(model: "test", messages: [ChatMessage(role: .user, text: "继续")])
        #expect(try await fixture.runner(reply).run(service: service, request: request))
        #expect(reply.content == "之前的内容\n\n接着讲。")
        #expect(reply.studyReferences == [reference])
        let empty = StudyAssistantService { _, _ in .events([.text("  ")]) }
        await #expect(throws: StudyAssistantTools.ArgumentError.self) { try await fixture.runner(fixture.reply()).run(service: empty, request: request) }
    }

    @Test func generationCenterPersistsAssistantAndDoesNotExposeToolsToOrdinaryChats() async throws {
        let fixture = try StudyAssistantFixture()
        let id = fixture.card.id
        let service = StudyAssistantService { request, index in
            if request.tools.isEmpty { return .events([.text("普通回答")]) }
            if index == 20 { return .events([.text("导数知识 [资料1]"), .usage(input: 50, output: 5)]) }
            return .events([.toolCall(studyRead(kind: .card, id: id)), .usage(input: 20, output: 2)])
        }
        let generation = GenerationCenter(service: service)
        try generation.send("找导数知识", in: fixture.current, context: fixture.context)
        for _ in 0..<400 {
            if !generation.isGenerating(fixture.current) { break }
            try await Task.sleep(for: .milliseconds(5))
        }
        let reply = try #require(fixture.current.sortedMessages.last)
        #expect(reply.status == .complete && reply.studyReferences.first?.recordID == id)
        #expect(reply.content == "导数知识 [资料1]" && service.requests.count == 21)
        #expect(reply.inputTokens == 450 && reply.outputTokens == 45)
        #expect(generation.studyActivity.isEmpty)
        let saved = try ModelContext(fixture.container).fetch(FetchDescriptor<Conversation>()).first { $0.id == fixture.current.id }
        #expect(saved?.isStudyAssistant == true && saved?.sortedMessages.last?.studyReferences.first?.recordID == id)
        #expect(saved?.sortedMessages.last?.status == .complete)
        #expect(ConversationExporter.markdown(for: fixture.current).contains("[资料1] 知识卡"))
        #expect(NoteDraftRequest.reply(reply).items.last?.content.contains("[资料1] 知识卡") == true)
        fixture.conversation.model = fixture.model
        try generation.send("普通问题", in: fixture.conversation, context: fixture.context)
        for _ in 0..<400 {
            if !generation.isGenerating(fixture.conversation) { break }
            try await Task.sleep(for: .milliseconds(5))
        }
        #expect(service.requests.last?.tools.isEmpty == true)
        #expect(fixture.conversation.sortedMessages.last?.content == "普通回答")
    }
}

/// 用真实 SwiftUI 环境渲染入口、会话和引用页，截图保留在测试结果中供界面检查。
@MainActor
final class StudyAssistantPresentationTests: XCTestCase {
    func testHomeAndReferenceScreensRender() async throws {
        let fixture = try StudyAssistantFixture()
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let previous = scene.windows.first { $0.isKeyWindow }
        let window = UIWindow(windowScene: scene)
        window.windowLevel = .normal + 1
        let navigation = AppNavigation()
        let generation = GenerationCenter()
        let compilations = CompilationCenter()
        let toasts = ToastCenter()
        defer {
            window.isHidden = true
            window.rootViewController = nil
            previous?.makeKeyAndVisible()
        }

        func capture<V: View>(_ view: V, name: String, style: UIUserInterfaceStyle = .light, expectedText: String? = nil) async throws {
            func webViews(in view: UIView) -> [WKWebView] {
                (view as? WKWebView).map { [$0] } ?? view.subviews.flatMap { webViews(in: $0) }
            }
            let root = view.modelContainer(fixture.container)
                .environment(navigation).environment(generation).environment(compilations).environment(toasts)
            let host = UIHostingController(rootView: root)
            host.overrideUserInterfaceStyle = style
            window.rootViewController = host
            window.makeKeyAndVisible()
            host.view.layoutIfNeeded()
            try await Task.sleep(for: .milliseconds(650))
            if let expectedText {
                var rendered = false
                let deadline = Date().addingTimeInterval(30)
                while Date() < deadline && !rendered {
                    for webView in webViews(in: host.view) {
                        let text = try? await webView.evaluateJavaScript("document.body.innerText") as? String
                        if text?.contains(expectedText) == true { rendered = true; break }
                    }
                    if !rendered { try await Task.sleep(for: .milliseconds(100)) }
                }
                XCTAssertTrue(rendered, "正文应渲染完成：\(expectedText)")
            }
            host.view.layoutIfNeeded()
            XCTAssertGreaterThan(host.view.bounds.width, 300)
            // WKWebView 使用独立绘制层，drawHierarchy 不包含正文，需要单独截图合成。
            var webImages: [(UIImage, CGRect)] = []
            for webView in webViews(in: host.view) where webView.bounds.width > 0 && webView.bounds.height > 0 {
                let image = try await webView.takeSnapshot(configuration: nil)
                webImages.append((image, webView.convert(webView.bounds, to: host.view)))
            }
            let image = UIGraphicsImageRenderer(bounds: host.view.bounds).image { _ in
                host.view.drawHierarchy(in: host.view.bounds, afterScreenUpdates: true)
                for (image, frame) in webImages { image.draw(in: frame) }
            }
            let attachment = XCTAttachment(image: image)
            attachment.name = name
            attachment.lifetime = .keepAlways
            add(attachment)
        }

        try await capture(NavigationStack { StudyAssistantHomeView() }, name: "学习助手入口")
        let reply = fixture.reply()
        reply.content = "可以先复习导数符号与单调性的联系，再做一道原题。[资料1]"
        reply.status = .complete
        reply.studyReferences = [StudyReference(number: 1, kind: .card, recordID: fixture.card.id, title: fixture.card.title)]
        try fixture.context.save()
        try await capture(NavigationStack { ChatView(conversation: fixture.current) }, name: "学习助手回答与本地引用", style: .dark, expectedText: "可以先复习导数符号")
        try await capture(StudyReferenceSheet(reference: reply.studyReferences[0]), name: "打开知识卡原记录", expectedText: "函数严格递减")
        let missing = StudyReference(number: 2, kind: .mistake, recordID: UUID(), title: "已删除的错题")
        try await capture(StudyReferenceSheet(reference: missing), name: "原记录已删除")
        XCTAssertEqual(fixture.current.sortedMessages.count, 1)
        XCTAssertEqual(fixture.card.content, "导数为负的区间内，函数严格递减。")
    }
}
