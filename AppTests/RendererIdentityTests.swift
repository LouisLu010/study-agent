import SwiftUI
import Testing
import WebKit
@testable import StudyAgent

@MainActor
@Suite(.serialized)
struct RendererIdentityTests {
    @Test func changingMessageReloadsRendererAndClearsQuizAnswer() async throws {
        let firstID = UUID()
        let page = try RendererTestPage(
            messageID: firstID,
            content: quiz(question: "6×7 是多少？", answer: 42)
        )
        defer { page.close() }

        try await page.waitForQuestion("6×7 是多少？")
        try await page.setPageToken("first-message")
        try await page.submit("42")
        try await page.waitForResultCount(1)
        let answered = try await page.snapshot()
        #expect(answered.input == "42")
        #expect(answered.disabled)
        #expect(answered.submitHidden)

        page.update(
            messageID: UUID(),
            content: quiz(question: "2×3 是多少？", answer: 6)
        )
        try await page.waitForQuestion("2×3 是多少？")
        let fresh = try await page.snapshot()
        #expect(fresh.input.isEmpty)
        #expect(!fresh.disabled)
        #expect(!fresh.submitHidden)
        #expect(fresh.savedInput == nil)
        #expect(fresh.pageToken == nil)
        #expect(page.quizResults.count == 1)

        try await page.submit("6")
        try await page.waitForResultCount(2)
        let secondResult = try #require(page.quizResults.last)
        #expect((secondResult["question"] as? [String: Any])?["question"] as? String == "2×3 是多少？")
        #expect((secondResult["answer"] as? [String: Any])?["input"] as? String == "6")
        #expect(secondResult["correct"] as? Bool == true)
    }

    @Test func streamingUpdatesOfSameMessageKeepPageAndSubmittedAnswer() async throws {
        let messageID = UUID()
        let markdown = quiz(question: "6×7 是多少？", answer: 42)
        let page = try RendererTestPage(
            messageID: messageID,
            content: markdown + "\n第一段说明",
            isStreaming: true
        )
        defer { page.close() }

        try await page.waitForQuestion("6×7 是多少？")
        try await page.setPageToken("same-message")
        try await page.submit("42")
        try await page.waitForResultCount(1)

        page.update(messageID: messageID, content: markdown + "\n新增说明", isStreaming: true)
        try await page.waitForText("新增说明")
        let streaming = try await page.snapshot()
        #expect(streaming.input == "42")
        #expect(streaming.savedInput == "42")
        #expect(streaming.disabled)
        #expect(streaming.submitHidden)
        #expect(streaming.pageToken == "same-message")

        page.update(messageID: messageID, content: markdown + "\n最终说明")
        try await page.waitForText("最终说明")
        let finished = try await page.snapshot()
        #expect(finished.input == "42")
        #expect(finished.savedInput == "42")
        #expect(finished.disabled)
        #expect(finished.submitHidden)
        #expect(finished.pageToken == "same-message")
        #expect(page.quizResults.count == 1)
    }

    @Test func staleCompletionAndReadyDoNotConsumeNextPageBeforeNavigationFinishes() async throws {
        let messageID = UUID()
        let markdown = quiz(question: "6×7 是多少？", answer: 42)
        let page = try RendererTestPage(messageID: messageID, content: markdown)
        defer { page.close() }
        try await page.waitForQuestion("6×7 是多少？")

        page.holdRenderCompletions()
        page.update(messageID: messageID, content: markdown + "\n旧页面更新")
        try await page.waitForHeldRenderCompletions(1)
        let requestCount = page.renderRequestCount

        page.holdNavigationCompletion()
        page.update(
            messageID: UUID(),
            content: quiz(question: "2×3 是多少？", answer: 6),
            componentStateJSON: #"{"c0":{"answers":{"0":{"input":"6"}}}}"#
        )
        try await page.waitForHeldNavigation()
        page.deliverBridgeReady()
        page.releaseOldestRenderCompletion()
        // 旧完成回调会再向 MainActor 排一个 Task，让它实际运行后检查调度次数。
        try await Task.sleep(for: .milliseconds(20))
        #expect(page.renderRequestCount == requestCount)

        page.releaseRenderCompletions()
        page.releaseNavigationCompletion()
        try await page.waitForQuestion("2×3 是多少？")
        let snapshot = try await page.snapshot()
        #expect(snapshot.input == "6")
        #expect(snapshot.savedInput == "6")
        #expect(snapshot.disabled)
        #expect(page.quizResults.isEmpty)
    }

    @Test func staleCompletionDoesNotFinishCurrentPagesActiveRender() async throws {
        let messageID = UUID()
        let markdown = quiz(question: "6×7 是多少？", answer: 42)
        let page = try RendererTestPage(messageID: messageID, content: markdown)
        defer { page.close() }
        try await page.waitForQuestion("6×7 是多少？")

        page.holdRenderCompletions()
        page.update(messageID: messageID, content: markdown + "\n旧页面更新")
        try await page.waitForHeldRenderCompletions(1)
        let nextID = UUID()
        let nextMarkdown = quiz(question: "2×3 是多少？", answer: 6)
        page.update(messageID: nextID, content: nextMarkdown)
        try await page.waitForQuestion("2×3 是多少？")
        try await page.waitForHeldRenderCompletions(2)

        page.releaseOldestRenderCompletion()
        try await Task.sleep(for: .milliseconds(20))
        let requestCount = page.renderRequestCount
        page.update(messageID: nextID, content: nextMarkdown + "\n当前页面的后续内容")
        #expect(page.renderRequestCount == requestCount)

        page.releaseRenderCompletions()
        try await page.waitForText("当前页面的后续内容")
        let snapshot = try await page.snapshot()
        #expect(snapshot.input.isEmpty)
        #expect(!snapshot.disabled)
        #expect(page.quizResults.isEmpty)
    }

    @Test func staleBridgeMessagesDoNotReachNextMessageBeforeNavigationFinishes() async throws {
        let page = try RendererTestPage(
            messageID: UUID(),
            content: quiz(question: "6×7 是多少？", answer: 42)
        )
        defer { page.close() }
        try await page.waitForQuestion("6×7 是多少？")

        let nextID = UUID()
        page.holdNavigationCompletion()
        page.update(messageID: nextID, content: quiz(question: "2×3 是多少？", answer: 6))
        try await page.waitForHeldNavigation()

        // 模拟上一页已排队的消息在新导航完成前才送达。
        page.deliverBridgeMessage(name: "state", body: ["key": "c0", "state": ["input": "stale"]])
        page.deliverBridgeMessage(name: "quizResult", body: ["correct": false])
        page.deliverBridgeMessage(name: "height", body: NSNumber(value: 900))
        #expect(page.componentStates.isEmpty)
        #expect(page.quizResults.isEmpty)
        #expect(RenderCache.heights[nextID] == nil)

        page.releaseNavigationCompletion()
        try await page.waitForQuestion("2×3 是多少？")

        // 当前页就绪后，正常事件仍然交给对应的消息。
        page.deliverBridgeMessage(name: "state", body: ["key": "c0", "state": ["input": "current"]])
        page.deliverBridgeMessage(name: "quizResult", body: ["correct": true])
        page.deliverBridgeMessage(name: "height", body: NSNumber(value: 700))
        #expect(page.componentStates.count == 1)
        #expect(page.componentStates.last?.key == "c0")
        #expect((page.componentStates.last?.state as? [String: String])?["input"] == "current")
        #expect(page.quizResults.count == 1)
        #expect(page.quizResults.last?["correct"] as? Bool == true)
        #expect(RenderCache.heights[nextID] == 700)
    }

    private func quiz(question: String, answer: Int) -> String {
        """
        ```quiz
        {"questions":[{"type":"number","question":"\(question)","answer":\(answer)}]}
        ```

        """
    }
}

@MainActor
private final class RendererTestPage {
    struct Snapshot: Decodable {
        let input: String
        let disabled: Bool
        let submitHidden: Bool
        let savedInput: String?
        let pageToken: String?
    }

    private let coordinator = MessageWebView.Coordinator()
    private let webView: RendererCompletionWebView
    private let navigationDelegate: RendererTestNavigationDelegate
    private var messageIDs: Set<UUID> = []
    private(set) var componentStates: [(key: String, state: Any?)] = []
    private(set) var quizResults: [[String: Any]] = []

    init(messageID: UUID, content: String, isStreaming: Bool = false) throws {
        guard Bundle.main.url(forResource: "index", withExtension: "html", subdirectory: "Renderer") != nil else {
            throw RendererTestError.missingRendererAssets
        }
        let controller = WKUserContentController()
        let handler = RendererTestMessageHandler(coordinator: coordinator)
        for name in MessageWebView.Coordinator.messageNames {
            controller.add(handler, name: name)
        }
        let configuration = WKWebViewConfiguration()
        configuration.userContentController = controller
        webView = RendererCompletionWebView(frame: CGRect(x: 0, y: 0, width: 390, height: 844), configuration: configuration)
        navigationDelegate = RendererTestNavigationDelegate(coordinator: coordinator)
        webView.navigationDelegate = navigationDelegate
        coordinator.webView = webView
        coordinator.parent = makeParent(messageID: messageID, content: content, isStreaming: isStreaming)
        coordinator.loadRenderer()
        coordinator.update(content: content, isStreaming: isStreaming)
    }

    func update(messageID: UUID, content: String, isStreaming: Bool = false, componentStateJSON: String = "") {
        var parent = makeParent(messageID: messageID, content: content, isStreaming: isStreaming)
        parent.componentStateJSON = componentStateJSON
        coordinator.updateParent(parent)
        coordinator.update(content: content, isStreaming: isStreaming)
    }

    var renderRequestCount: Int { webView.renderRequestCount }

    func holdRenderCompletions() { webView.holdsRenderCompletions = true }

    func releaseOldestRenderCompletion() { webView.releaseOldestRenderCompletion() }

    func releaseRenderCompletions() {
        webView.holdsRenderCompletions = false
        while webView.heldRenderCompletionCount > 0 {
            webView.releaseOldestRenderCompletion()
        }
    }

    func holdNavigationCompletion() { navigationDelegate.holdsCompletion = true }

    func releaseNavigationCompletion() {
        navigationDelegate.holdsCompletion = false
        navigationDelegate.releaseCompletion(webView)
    }

    func deliverBridgeReady() { coordinator.receive(name: "ready", body: true) }

    func deliverBridgeMessage(name: String, body: Any) { coordinator.receive(name: name, body: body) }

    func waitForHeldRenderCompletions(_ count: Int) async throws {
        try await waitUntil("没有收到 \(count) 次渲染完成回调") { webView.heldRenderCompletionCount >= count }
    }

    func waitForHeldNavigation() async throws {
        try await waitUntil("没有收到导航完成回调") { navigationDelegate.hasHeldCompletion }
    }

    func close() {
        MessageWebView.dismantleUIView(webView, coordinator: coordinator)
        webView.stopLoading()
        webView.navigationDelegate = nil
        coordinator.parent = nil
        coordinator.webView = nil
        for id in messageIDs {
            RenderCache.heights.removeValue(forKey: id)
        }
    }

    func waitForQuestion(_ question: String) async throws {
        let expected = try json(question)
        try await waitForJavaScript("document.querySelector('.quiz-text')?.textContent.trim() === \(expected)")
    }

    func waitForText(_ text: String) async throws {
        let expected = try json(text)
        try await waitForJavaScript("document.getElementById('content')?.textContent.includes(\(expected))")
    }

    func waitForResultCount(_ count: Int) async throws {
        try await waitUntil("没有收到 \(count) 次 quizResult") { quizResults.count >= count }
    }

    func setPageToken(_ token: String) async throws {
        let value = try json(token)
        _ = try await evaluate("window.__identityTestPageToken = \(value); JSON.stringify(true)")
    }

    func submit(_ answer: String) async throws {
        let value = try json(answer)
        _ = try await evaluate("""
            document.querySelector('.quiz-input').value = \(value);
            document.querySelector('.quiz-submit').click();
            JSON.stringify(true);
            """)
    }

    func snapshot() async throws -> Snapshot {
        let result = try await evaluate("""
            JSON.stringify({
                input: document.querySelector('.quiz-input').value,
                disabled: document.querySelector('.quiz-input').disabled,
                submitHidden: document.querySelector('.quiz-submit').hidden,
                savedInput: window.StudyRenderer.getOptions().state.c0?.answers?.[0]?.input ?? null,
                pageToken: window.__identityTestPageToken ?? null,
            })
            """)
        return try JSONDecoder().decode(Snapshot.self, from: Data(result.utf8))
    }

    private func makeParent(messageID: UUID, content: String, isStreaming: Bool) -> MessageWebView {
        messageIDs.insert(messageID)
        return MessageWebView(
            messageID: messageID,
            content: content,
            isStreaming: isStreaming,
            height: .constant(60),
            onComponentState: { [weak self] key, state in self?.componentStates.append((key, state)) },
            onQuizResult: { [weak self] result in self?.quizResults.append(result) }
        )
    }

    private func waitForJavaScript(_ condition: String) async throws {
        let deadline = Date().addingTimeInterval(15)
        while Date() < deadline {
            // 页面重载期间脚本可能暂时不可用，下一轮继续检查。
            if (try? await evaluate("JSON.stringify(Boolean(\(condition)))")) == "true" { return }
            try await Task.sleep(for: .milliseconds(20))
        }
        throw RendererTestError.timedOut(condition)
    }

    private func waitUntil(_ description: String, condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(15)
        while Date() < deadline {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(20))
        }
        throw RendererTestError.timedOut(description)
    }

    private func evaluate(_ script: String) async throws -> String {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<String, Error>) in
            webView.evaluateJavaScript(script) { value, error in
                if let error {
                    continuation.resume(throwing: error)
                } else if let result = value as? String {
                    continuation.resume(returning: result)
                } else {
                    continuation.resume(throwing: RendererTestError.unexpectedJavaScriptResult)
                }
            }
        }
    }

    private func json(_ value: String) throws -> String {
        String(decoding: try JSONEncoder().encode(value), as: UTF8.self)
    }
}

// JavaScript 仍由真实 WebView 执行，只延后完成通知来稳定复现跨导航回调的顺序。
@MainActor
private final class RendererCompletionWebView: WKWebView {
    var holdsRenderCompletions = false
    private var heldCompletions: [() -> Void] = []
    private(set) var renderRequestCount = 0
    var heldRenderCompletionCount: Int { heldCompletions.count }

    override func __callAsyncJavaScript(
        _ functionBody: String,
        arguments: [String: Any]?,
        inFrame frame: WKFrameInfo?,
        in contentWorld: WKContentWorld,
        completionHandler: (@MainActor @Sendable (Any?, (any Error)?) -> Void)? = nil
    ) {
        let isRender = functionBody.contains("window.StudyRenderer.render(")
        if isRender { renderRequestCount += 1 }
        super.__callAsyncJavaScript(functionBody, arguments: arguments, inFrame: frame, in: contentWorld) { [weak self] value, error in
            guard let self, isRender, self.holdsRenderCompletions else {
                completionHandler?(value, error)
                return
            }
            self.heldCompletions.append { completionHandler?(value, error) }
        }
    }

    func releaseOldestRenderCompletion() {
        guard !heldCompletions.isEmpty else { return }
        heldCompletions.removeFirst()()
    }
}

@MainActor
private final class RendererTestNavigationDelegate: NSObject, WKNavigationDelegate {
    private weak var coordinator: MessageWebView.Coordinator?
    private var heldNavigation: WKNavigation?
    var holdsCompletion = false
    var hasHeldCompletion: Bool { heldNavigation != nil }

    init(coordinator: MessageWebView.Coordinator) {
        self.coordinator = coordinator
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        if holdsCompletion {
            heldNavigation = navigation
        } else {
            coordinator?.webView(webView, didFinish: navigation)
        }
    }

    func releaseCompletion(_ webView: WKWebView) {
        guard let navigation = heldNavigation else { return }
        heldNavigation = nil
        coordinator?.webView(webView, didFinish: navigation)
    }
}

@MainActor
private final class RendererTestMessageHandler: NSObject, WKScriptMessageHandler {
    private weak var coordinator: MessageWebView.Coordinator?

    init(coordinator: MessageWebView.Coordinator) {
        self.coordinator = coordinator
    }

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        coordinator?.receive(name: message.name, body: message.body)
    }
}

private enum RendererTestError: Error {
    case missingRendererAssets
    case unexpectedJavaScriptResult
    case timedOut(String)
}
