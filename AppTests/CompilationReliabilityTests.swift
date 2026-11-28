import Foundation
import StudyKit
import SwiftData
import Testing
import WebKit
@testable import StudyAgent

@MainActor
@Suite struct CompilationReliabilityTests {
    @Test func changingAIExplanationInvalidatesPersistedPDF() throws {
        let container = try ModelContainer(
            for: Compilation.self, ExamQuestion.self, StoredImage.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
        let context = ModelContext(container)
        let compilation = Compilation(request: "数学题")
        context.insert(compilation)
        let question = ExamQuestion(paperTitle: "试卷", year: "2026", number: "1", index: 0)
        question.compilation = compilation
        question.answer = "旧答案"
        question.answerKind = .site
        question.answerSite = "旧来源"
        context.insert(question)

        for answer in ["", "新答案", "新答案与完整解析"] {
            compilation.pdfData = Data("旧 PDF".utf8)
            compilation.pdfGeneratedAt = .now
            compilation.pdfPending = true
            CompilationCenter.setAIExplanation(answer, for: question)
            try context.save()

            let reloaded = ModelContext(container)
            let saved = try #require(reloaded.fetch(FetchDescriptor<Compilation>()).first)
            let savedQuestion = try #require(saved.questions?.first)
            #expect(saved.pdfData == nil)
            #expect(saved.pdfGeneratedAt == nil)
            #expect(!saved.pdfPending)
            #expect(savedQuestion.answer == answer)
            #expect(savedQuestion.answerKind == .ai)
            #expect(savedQuestion.answerSite.isEmpty)
            #expect(CompilationPDF.document(for: saved).questions.first?.answer == answer)
        }
    }

    @Test func publishingMatchingPDFStoresTheSnapshot() throws {
        let compilation = Compilation(request: "数学题")
        compilation.pdfPending = true
        let snapshot = CompilationPDF.document(for: compilation)
        let data = Data("当前 PDF".utf8)
        try CompilationPDF.publish(data, for: compilation, snapshot: snapshot)
        #expect(compilation.pdfData == data)
        #expect(compilation.pdfGeneratedAt != nil)
        #expect(!compilation.pdfPending)
    }

    @Test func oldRenderCannotOverwriteUpdatedAnswerOrNewerPDF() throws {
        let container = try ModelContainer(
            for: Compilation.self, ExamQuestion.self, StoredImage.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
        let context = ModelContext(container)
        let compilation = Compilation(request: "数学题")
        context.insert(compilation)
        let question = ExamQuestion(paperTitle: "试卷", year: "2026", number: "1", index: 0)
        question.compilation = compilation
        context.insert(question)
        CompilationCenter.setAIExplanation("尚未写完", for: question)
        let oldSnapshot = CompilationPDF.document(for: compilation)

        CompilationCenter.setAIExplanation("完整的新答案", for: question)
        #expect(throws: CompilationPDF.GenerationError.contentChanged) {
            try CompilationPDF.publish(Data("过期 PDF".utf8), for: compilation, snapshot: oldSnapshot)
        }
        #expect(compilation.pdfData == nil)
        #expect(compilation.pdfGeneratedAt == nil)

        let currentSnapshot = CompilationPDF.document(for: compilation)
        let currentData = Data("最新 PDF".utf8)
        try CompilationPDF.publish(currentData, for: compilation, snapshot: currentSnapshot)
        let generatedAt = compilation.pdfGeneratedAt
        #expect(throws: CompilationPDF.GenerationError.contentChanged) {
            try CompilationPDF.publish(Data("过期 PDF".utf8), for: compilation, snapshot: oldSnapshot)
        }
        #expect(compilation.pdfGeneratedAt == generatedAt)
        try context.save()

        let reloaded = ModelContext(container)
        let saved = try #require(reloaded.fetch(FetchDescriptor<Compilation>()).first)
        #expect(saved.pdfData == currentData)
        #expect(saved.questions?.first?.answer == "完整的新答案")
    }

    @Test func changingPDFOptionsRejectsPendingRender() {
        let compilation = Compilation(request: "数学题")
        let snapshot = CompilationPDF.document(for: compilation)
        compilation.includeAnswers.toggle()
        #expect(throws: CompilationPDF.GenerationError.contentChanged) {
            try CompilationPDF.publish(Data("过期 PDF".utf8), for: compilation, snapshot: snapshot)
        }
        #expect(compilation.pdfData == nil)
    }

    @Test func pageFailureBeforeWaitingIsPreserved() async throws {
        let loader = CompilationPDF.PageLoader()
        let webView = WKWebView()
        loader.webView(webView, didFailProvisionalNavigation: nil, withError: URLError(.cannotFindHost))
        do {
            try await loader.wait()
            Issue.record("页面加载失败后不应成功")
        } catch {
            #expect((error as? URLError)?.code == .cannotFindHost)
        }
    }

    @Test func pageNavigationFailureReleasesWaiter() async {
        let loader = CompilationPDF.PageLoader()
        let webView = WKWebView()
        let task = Task { try await loader.wait() }
        await Task.yield()
        loader.webView(webView, didFail: nil, withError: URLError(.cannotConnectToHost))
        do {
            try await task.value
            Issue.record("导航失败后不应成功")
        } catch {
            #expect((error as? URLError)?.code == .cannotConnectToHost)
        }
    }

    @Test func terminatedWebContentFailsInsteadOfHanging() async {
        let loader = CompilationPDF.PageLoader()
        loader.webViewWebContentProcessDidTerminate(WKWebView())
        do {
            try await loader.wait()
            Issue.record("WebContent 退出后不应成功")
        } catch {
            #expect((error as? URLError)?.code == .networkConnectionLost)
        }
    }

    @Test func pageLoadTimeoutReleasesWaiter() async {
        let loader = CompilationPDF.PageLoader()
        do {
            try await loader.wait(timeout: .milliseconds(1))
            Issue.record("没有加载回调时应超时")
        } catch {
            #expect((error as? URLError)?.code == .timedOut)
        }
    }

    @Test func cancellingPageLoadReleasesWaiter() async {
        let loader = CompilationPDF.PageLoader()
        let task = Task { try await loader.wait() }
        await Task.yield()
        task.cancel()
        do {
            try await task.value
            Issue.record("取消页面加载后不应成功")
        } catch {
            #expect(error is CancellationError)
        }
    }

    @Test func alreadyCancelledPageLoadDoesNotWait() async {
        let loader = CompilationPDF.PageLoader()
        let task = Task { try await loader.wait() }
        task.cancel()
        do {
            try await task.value
            Issue.record("已取消的任务不应开始等待")
        } catch {
            #expect(error is CancellationError)
        }
    }

    @Test func duplicateNavigationCallbacksKeepFirstResult() async throws {
        let loader = CompilationPDF.PageLoader()
        let webView = WKWebView()
        let task = Task { try await loader.wait() }
        await Task.yield()
        loader.webView(webView, didFinish: nil)
        loader.webView(webView, didFail: nil, withError: URLError(.unknown))
        loader.webViewWebContentProcessDidTerminate(webView)
        try await task.value
        // 结果被保留，后续读取也不会再次挂起或覆盖首次成功。
        try await loader.wait()
    }
}
