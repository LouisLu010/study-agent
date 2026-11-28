import Foundation
import StudyKit
import SwiftData
import Testing
@testable import StudyAgent

private enum BatchCollectorTestError: Error {
    case scriptExhausted
    case unexpectedPage(String)
    case unexpectedImage
}

/// 脚本耗尽立即报错，所有请求只记录在内存中，不会转交真实服务。
private final class BatchCollectorService: ChatService, @unchecked Sendable {
    private let lock = NSLock()
    private var replies: [String]
    private var reviewReplies: [String]?
    private var captured: [ChatRequest] = []

    init(_ replies: [String], reviewReplies: [String]? = nil) {
        self.replies = replies
        self.reviewReplies = reviewReplies
    }

    var requests: [ChatRequest] {
        lock.lock()
        defer { lock.unlock() }
        return captured
    }

    var reviewRequests: [ChatRequest] { requests.filter(Self.isReview) }

    private static func isReview(_ request: ChatRequest) -> Bool {
        request.systemPrompt?.contains("is_question") == true
    }

    /// 默认复核只选择请求里实际提供的原块，测试可以单独指定删块或失败响应。
    private static func preservingReview(_ request: ChatRequest) -> String? {
        guard let text = request.messages.last?.text, let marker = text.range(of: "\n候选题：\n"),
              let candidates = JSONValue.parse(String(text[marker.upperBound...]))?.arrayValue
        else { return nil }
        var items: [JSONValue] = []
        for candidate in candidates {
            guard let id = candidate["id"]?.stringValue, let blocks = candidate["blocks"]?.arrayValue else { return nil }
            let question = blocks.filter { $0["origin"]?.stringValue == "question" }.compactMap { $0["id"]?.stringValue }
            let answer = blocks.filter { $0["origin"]?.stringValue == "answer" }.compactMap { $0["id"]?.stringValue }
            items.append([
                "id": .string(id), "is_question": .bool(!question.isEmpty),
                "question": .array(question.map(JSONValue.string)),
                "answer": .array((question.isEmpty ? [] : answer).map(JSONValue.string)), "note": "测试保留原块",
            ])
        }
        return JSONValue.object(["items": .array(items)]).jsonString
    }

    func streamChat(_ request: ChatRequest) -> AsyncThrowingStream<ChatStreamEvent, any Error> {
        lock.lock()
        captured.append(request)
        let reply: String?
        if Self.isReview(request) {
            if reviewReplies != nil {
                reply = reviewReplies!.isEmpty ? nil : reviewReplies!.removeFirst()
            } else {
                reply = Self.preservingReview(request)
            }
        } else {
            reply = replies.isEmpty ? nil : replies.removeFirst()
        }
        lock.unlock()
        return AsyncThrowingStream { continuation in
            guard let reply else {
                continuation.finish(throwing: BatchCollectorTestError.scriptExhausted)
                return
            }
            continuation.yield(.text(reply))
            continuation.finish()
        }
    }
}

@MainActor
private final class BatchCollectorFixture {
    let container: ModelContainer
    let context: ModelContext
    let compilation: Compilation
    let paper: PaperPlan
    let model = ChatModel(modelID: "deepseek-flash")
    let directory = FileManager.default.temporaryDirectory.appending(path: "CompilationBatchTests-" + UUID().uuidString)
    var downloads: [URL] = []

    init(sources: [String]) throws {
        container = try ModelContainer(
            for: Compilation.self, ExamQuestion.self, StoredImage.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
        context = ModelContext(container)
        compilation = Compilation(request: "2025 年北京卷化学有机大题")
        compilation.subject = .chemistry
        paper = PaperPlan(title: "2025 年普通高等学校招生全国统一考试（北京卷）化学", shortTitle: "北京卷", year: "2025", sourceURLs: sources)
        compilation.papers = [paper]
        context.insert(compilation)
        try context.save()
    }

    func collector(
        service: BatchCollectorService, pages: [String: String], onlyNumber: String? = nil,
        imageLoader: @escaping (URL, URL) async throws -> (Data, String) = { _, _ in throw BatchCollectorTestError.unexpectedImage }
    ) -> CompilationBatchCollector {
        let store = CompilationSourceStore(directory: directory, download: { url in
            self.downloads.append(url)
            guard let html = pages[url.absoluteString] else { throw BatchCollectorTestError.unexpectedPage(url.absoluteString) }
            return html
        })
        let session = CompilationBatchSession(compilation: compilation, model: model, service: service, log: { _, _ in })
        return CompilationBatchCollector(session: session, context: context, paper: paper, store: store, onlyNumber: onlyNumber, imageLoader: imageLoader)
    }

    func removeFiles() { try? FileManager.default.removeItem(at: directory) }
}

@MainActor
@Suite struct CompilationBatchCollectorTests {
    private let pageURL = URL(string: "https://example.org/beijing-2025")!
    private let paperHTML = """
    <html><head><title>2025 年北京卷化学原题</title></head><body>
    <h1>2025 年普通高等学校招生全国统一考试（北京卷）化学</h1>
    <p>17．有机物甲可以发生加成反应，请写出产物。<img src="/route.png"></p>
    <p>18．有机物乙可以发生取代反应，请写出反应条件。</p>
    </body></html>
    """

    private func range(
        _ number: String, in document: PaperDocument, source: String = "S1", marker: String
    ) throws -> JSONValue {
        let block = try #require(document.blocks.first { $0.text.contains(marker) })
        return ["number": .string(number), "source_id": .string(source), "start_id": .string(block.id), "end_id": .string(block.id), "group": false]
    }

    private func selection(
        questions: [JSONValue] = [], links: [JSONValue] = [], reuse: [String] = [], matches: Bool = true, complete: Bool = true
    ) -> String {
        JSONValue.object([
            "matches_paper": .bool(matches), "questions": .array(questions), "links": .array(links),
            "reuse": .array(reuse.map(JSONValue.string)), "complete": .bool(complete), "note": "测试结果",
        ]).jsonString
    }

    private func reviewReply(
        _ candidate: CompilationQuestionReview.Candidate, question: [String], answer: [String] = [], isQuestion: Bool = true
    ) -> String {
        JSONValue.object(["items": .array([[
            "id": .string(candidate.id), "is_question": .bool(isQuestion),
            "question": .array(question.map(JSONValue.string)), "answer": .array(answer.map(JSONValue.string)),
            "note": .string(isQuestion ? "已核实并保留原题" : "仅为网页导航与广告，不是题目"),
        ]])]).jsonString
    }

    /// 选区与复核 ID 均取自实际提取结果，避免测试假定 Markdown 拆块数量。
    private func fullPageCandidate(
        html: String, number: String = "17"
    ) throws -> (selection: String, candidate: CompilationQuestionReview.Candidate) {
        let document = PaperDocument(html: html, url: pageURL)
        let first = try #require(document.blocks.first)
        let last = try #require(document.blocks.last)
        let result = try document.extract(startID: first.id, endID: last.id).get()
        let selected: JSONValue = [
            "number": .string(number), "source_id": "S1", "start_id": .string(first.id), "end_id": .string(last.id), "group": false,
        ]
        return (
            selection(questions: [selected]),
            CompilationQuestionReview.Candidate(id: "Q1", number: number, content: result.content, answer: result.answer)
        )
    }

    @Test func aKnownPaperSavesTwoOriginalQuestionsWithBatchedSelectionAndReview() async throws {
        let fixture = try BatchCollectorFixture(sources: [pageURL.absoluteString])
        defer { fixture.removeFiles() }
        let document = PaperDocument(html: paperHTML, url: pageURL)
        let response = try selection(questions: [range("17", in: document, marker: "有机物甲"), range("18", in: document, marker: "有机物乙")])
        let service = BatchCollectorService([response])
        var images: [URL] = []
        let collector = fixture.collector(service: service, pages: [pageURL.absoluteString: paperHTML], imageLoader: { url, referer in
            images.append(url)
            #expect(referer == self.pageURL)
            return (Data([0x89, 0x50, 0x4E, 0x47]), "image/png")
        })

        let finished = try await collector.collect()

        #expect(finished.collectionComplete)
        #expect(finished.state == .done)
        #expect(finished.found == 2)
        #expect(service.requests.count == 2)
        #expect(service.reviewRequests.count == 1)
        #expect(service.requests.allSatisfy { !$0.webSearch && $0.tools.isEmpty })
        #expect(fixture.downloads == [pageURL])
        #expect(images == [URL(string: "https://example.org/route.png")!])
        let saved = try ModelContext(fixture.container).fetch(FetchDescriptor<ExamQuestion>()).sorted { $0.number < $1.number }
        #expect(saved.map(\.number) == ["17", "18"])
        #expect(saved.allSatisfy { $0.status == .complete && $0.sourceURL == pageURL.absoluteString })
        #expect(saved.first?.content.contains("有机物甲") == true)
        #expect(saved.first?.content.contains("sa-asset:") == true)
        #expect(saved.first?.images?.count == 1)
        #expect(saved.last?.content.contains("有机物乙") == true)
    }

    @Test func missingSourcesTriggerOneNativeSearchThenLocalExtraction() async throws {
        let fixture = try BatchCollectorFixture(sources: [])
        defer { fixture.removeFiles() }
        let html = "<html><head><title>2025 北京卷化学</title></head><body><p>17．有机物甲的反应产物是什么？</p></body></html>"
        let document = PaperDocument(html: html, url: pageURL)
        let response = try selection(questions: [range("17", in: document, marker: "有机物甲")])
        let service = BatchCollectorService([#"{"sources":["https://example.org/beijing-2025"]}"#, response])

        let finished = try await fixture.collector(service: service, pages: [pageURL.absoluteString: html]).collect()

        #expect(finished.collectionComplete)
        #expect(finished.found == 1)
        #expect(service.requests.count == 3)
        #expect(service.reviewRequests.count == 1)
        #expect(service.requests.map(\.webSearch) == [true, false, false])
        #expect(service.requests.first?.webSearchDialect == .deepSeek)
        #expect(service.requests.allSatisfy { $0.tools.isEmpty })
        #expect(fixture.downloads == [pageURL])
        #expect(fixture.compilation.papers.first?.sourceURLs == [pageURL.absoluteString])
    }

    @Test func aCompleteDirectoryOpensBothRealLinksWithoutSearching() async throws {
        let fixture = try BatchCollectorFixture(sources: [pageURL.absoluteString])
        defer { fixture.removeFiles() }
        let directory = """
        <html><head><title>2025 北京卷化学完整目录</title></head><body>
        <p>2025 年北京卷化学试题目录</p><p><a href="/q17">第 17 题有机大题</a></p><p><a href="/q18">第 18 题有机大题</a></p>
        </body></html>
        """
        let firstURL = URL(string: "https://example.org/q17")!
        let secondURL = URL(string: "https://example.org/q18")!
        let firstHTML = "<html><head><title>2025 北京卷化学第 17 题</title></head><body><p>17．有机物甲可以如何合成？</p></body></html>"
        let secondHTML = "<html><head><title>2025 北京卷化学第 18 题</title></head><body><p>18．有机物乙可以如何合成？</p></body></html>"
        let directoryDocument = PaperDocument(html: directory, url: pageURL)
        let firstLink = try #require(directoryDocument.links.first { $0.url == firstURL.absoluteString })
        let secondLink = try #require(directoryDocument.links.first { $0.url == secondURL.absoluteString })
        let directoryReply = selection(links: [
            ["source_id": "S1", "link_id": .string(firstLink.id)],
            ["source_id": "S1", "link_id": .string(secondLink.id)],
        ])
        let firstReply = try selection(questions: [range("17", in: PaperDocument(html: firstHTML, url: firstURL), source: "S2", marker: "有机物甲")])
        let secondReply = try selection(questions: [range("18", in: PaperDocument(html: secondHTML, url: secondURL), source: "S3", marker: "有机物乙")])
        let service = BatchCollectorService([directoryReply, firstReply, secondReply])

        let finished = try await fixture.collector(service: service, pages: [
            pageURL.absoluteString: directory, firstURL.absoluteString: firstHTML, secondURL.absoluteString: secondHTML,
        ]).collect()

        #expect(finished.collectionComplete)
        #expect(finished.found == 2)
        #expect(service.requests.count == 5)
        #expect(service.reviewRequests.count == 2)
        #expect(service.requests.allSatisfy { !$0.webSearch && $0.tools.isEmpty })
        #expect(fixture.downloads == [pageURL, firstURL, secondURL])
        #expect(Set(fixture.compilation.sortedQuestions.map(\.number)) == Set(["17", "18"]))
    }

    @Test func wrongPapersAndInvalidRangesCannotSaveQuestionsOrClaimCompletion() async throws {
        let invalid: JSONValue = ["number": "17", "source_id": "S1", "start_id": "B999", "end_id": "B1000", "group": false]
        for response in [selection(matches: false, complete: false), selection(questions: [invalid])] {
            let fixture = try BatchCollectorFixture(sources: [pageURL.absoluteString])
            defer { fixture.removeFiles() }
            let service = BatchCollectorService([response, #"{"sources":[]}"#])

            let finished = try await fixture.collector(service: service, pages: [pageURL.absoluteString: paperHTML]).collect()

            #expect(!finished.collectionComplete)
            #expect(finished.state == .failed)
            #expect(finished.found == 0)
            #expect(fixture.compilation.sortedQuestions.isEmpty)
            #expect(try fixture.context.fetchCount(FetchDescriptor<ExamQuestion>()) == 0)
            #expect(service.requests.filter(\.webSearch).count == 1)
        }
    }

    @Test func malformedSelectionFailsWithoutSavingASuccessfulEmptyPaper() async throws {
        let fixture = try BatchCollectorFixture(sources: [pageURL.absoluteString])
        defer { fixture.removeFiles() }
        let service = BatchCollectorService(["{}"])
        let collector = fixture.collector(service: service, pages: [pageURL.absoluteString: paperHTML])

        await #expect(throws: CompilationTools.ArgumentError.self) { try await collector.collect() }

        #expect(service.requests.count == 1)
        #expect(service.reviewRequests.isEmpty)
        #expect(fixture.compilation.sortedQuestions.isEmpty)
        #expect(fixture.compilation.papers.first?.collectionComplete == false)
    }

    @Test func cancellationWhileLoadingAnImageDoesNotSaveAnIncompleteQuestion() async throws {
        let fixture = try BatchCollectorFixture(sources: [pageURL.absoluteString])
        defer { fixture.removeFiles() }
        let document = PaperDocument(html: paperHTML, url: pageURL)
        let response = try selection(questions: [range("17", in: document, marker: "有机物甲")])
        let service = BatchCollectorService([response])
        let collector = fixture.collector(service: service, pages: [pageURL.absoluteString: paperHTML], imageLoader: { _, _ in
            withUnsafeCurrentTask { $0?.cancel() }
            return (Data([1, 2, 3]), "image/png")
        })
        let task = Task { try await collector.collect() }

        await #expect(throws: CancellationError.self) { try await task.value }

        #expect(service.requests.count == 2)
        #expect(service.reviewRequests.count == 1)
        #expect(fixture.compilation.sortedQuestions.isEmpty)
        #expect(try fixture.context.fetchCount(FetchDescriptor<ExamQuestion>()) == 0)
        #expect(try fixture.context.fetchCount(FetchDescriptor<StoredImage>()) == 0)
        #expect(fixture.compilation.papers.first?.collectionComplete == false)
    }

    @Test func previouslyCollectedWholePaperIsReviewedOnceBeforeReuse() async throws {
        let fixture = try BatchCollectorFixture(sources: [])
        defer { fixture.removeFiles() }
        let previous = Compilation(request: fixture.compilation.request)
        previous.subject = .chemistry
        var completed = fixture.paper
        completed.sourceURLs = [pageURL.absoluteString]
        completed.state = .done
        completed.collectionComplete = true
        completed.found = 1
        previous.papers = [completed]
        fixture.context.insert(previous)
        let original = ExamQuestion(paperTitle: completed.title, year: completed.year, number: "17", index: 0)
        original.content = "有机物甲可以发生加成反应。"
        original.status = .complete
        original.sourceURL = pageURL.absoluteString
        fixture.context.insert(original)
        original.compilation = previous
        try fixture.context.save()
        let service = BatchCollectorService([])

        let finished = try await fixture.collector(service: service, pages: [:]).collect()

        #expect(finished.collectionComplete)
        #expect(finished.found == 1)
        #expect(service.requests.count == 1)
        #expect(service.reviewRequests.count == 1)
        #expect(service.requests.allSatisfy { !$0.webSearch && $0.tools.isEmpty })
        #expect(fixture.downloads.isEmpty)
        let copied = try #require(fixture.compilation.sortedQuestions.first)
        #expect(copied.id != original.id)
        #expect(copied.content == original.content)
        #expect(CompilationQuestionReviewer.isReviewed(copied))
        #expect(previous.sortedQuestions.count == 1)

        let cachedService = BatchCollectorService([], reviewReplies: [])
        let repeated = try await fixture.collector(service: cachedService, pages: [:]).collect()
        #expect(repeated.collectionComplete)
        #expect(cachedService.requests.isEmpty)
        #expect(fixture.compilation.sortedQuestions.map(\.id) == [copied.id])
    }

    @Test func reviewRemovesWebsiteNoiseAndSeparatesAnUnmarkedAnswer() async throws {
        let fixture = try BatchCollectorFixture(sources: [pageURL.absoluteString])
        defer { fixture.removeFiles() }
        let html = """
        <html><body><p>首页 · 题库导航</p>
        <p>17．有机物甲与溴水反应，写出产物并说明原因。</p>
        <p>参考结论：产物为二溴代物，因为碳碳双键发生加成。</p>
        <p>下载 App 解锁更多试题。</p></body></html>
        """
        let input = try fullPageCandidate(html: html)
        #expect(input.candidate.answer.isEmpty)
        let question = try #require(input.candidate.blocks.first { $0.text.contains("有机物甲与溴水") })
        let answer = try #require(input.candidate.blocks.first { $0.text.contains("参考结论") })
        let service = BatchCollectorService([input.selection], reviewReplies: [
            reviewReply(input.candidate, question: [question.id], answer: [answer.id]),
        ])

        let finished = try await fixture.collector(service: service, pages: [pageURL.absoluteString: html]).collect()

        #expect(finished.collectionComplete)
        #expect(service.requests.count == 2)
        #expect(service.reviewRequests.count == 1)
        #expect(service.requests.allSatisfy { !$0.webSearch && $0.tools.isEmpty })
        let saved = try #require(ModelContext(fixture.container).fetch(FetchDescriptor<ExamQuestion>()).first)
        #expect(saved.content == question.text)
        #expect(saved.answer == answer.text)
        #expect(!saved.content.contains("参考结论"))
        #expect(!saved.content.contains("题库导航"))
        #expect(!saved.content.contains("下载 App"))
        #expect(saved.answerKind == .site)
        #expect(saved.answerSite == CompilationPlanner.siteName(for: pageURL))
        #expect(CompilationQuestionReviewer.isReviewed(saved))
    }

    @Test func reviewOnlyDownloadsRetainedQuestionAndAnswerImagesAndRemapsTheirIndices() async throws {
        let fixture = try BatchCollectorFixture(sources: [pageURL.absoluteString])
        defer { fixture.removeFiles() }
        let html = """
        <html><body><p>17．有机物甲的合成路线如下，完成反应式。</p>
        <p><img src="/advert.png"></p><p><img src="/question.png"></p>
        <p>参考结论：反应产物如下。</p><p><img src="/answer.png"></p></body></html>
        """
        let input = try fullPageCandidate(html: html)
        let stem = try #require(input.candidate.blocks.first { $0.text.contains("有机物甲的合成路线") })
        let questionImage = try #require(input.candidate.blocks.first { $0.text.contains("sa-image:1") })
        let answer = try #require(input.candidate.blocks.first { $0.text.contains("参考结论") })
        let answerImage = try #require(input.candidate.blocks.first { $0.text.contains("sa-image:2") })
        let service = BatchCollectorService([input.selection], reviewReplies: [
            reviewReply(input.candidate, question: [stem.id, questionImage.id], answer: [answer.id, answerImage.id]),
        ])
        var images: [URL] = []
        let finished = try await fixture.collector(service: service, pages: [pageURL.absoluteString: html], imageLoader: { url, _ in
            images.append(url)
            return (Data(url.lastPathComponent.utf8), "image/png")
        }).collect()

        #expect(finished.collectionComplete)
        #expect(images == [URL(string: "https://example.org/question.png")!, URL(string: "https://example.org/answer.png")!])
        let context = ModelContext(fixture.container)
        let saved = try #require(context.fetch(FetchDescriptor<ExamQuestion>()).first)
        let questionAsset = try #require(saved.images?.first { $0.data == Data("question.png".utf8) })
        let answerAsset = try #require(saved.images?.first { $0.data == Data("answer.png".utf8) })
        #expect(saved.content.contains("sa-asset:\(questionAsset.id.uuidString)"))
        #expect(saved.answer.contains("sa-asset:\(answerAsset.id.uuidString)"))
        #expect(!saved.content.contains("sa-asset:\(answerAsset.id.uuidString)"))
        #expect(!saved.answer.contains("sa-asset:\(questionAsset.id.uuidString)"))
        #expect(!saved.content.contains("sa-image:"))
        #expect(!saved.answer.contains("sa-image:"))
        #expect(try context.fetchCount(FetchDescriptor<StoredImage>()) == 2)
        #expect(saved.status == .complete)
    }

    @Test func rejectedWebsiteElementsAreNeverSavedAsAQuestion() async throws {
        let fixture = try BatchCollectorFixture(sources: [pageURL.absoluteString])
        defer { fixture.removeFiles() }
        let html = "<html><body><p>首页 · 高考题库导航</p><p>下载 App 查看更多试题。</p><p><img src=\"/advert.png\"></p></body></html>"
        let input = try fullPageCandidate(html: html)
        let service = BatchCollectorService([input.selection, #"{"sources":[]}"#], reviewReplies: [
            reviewReply(input.candidate, question: [], isQuestion: false),
        ])
        var imageAttempts = 0

        let finished = try await fixture.collector(service: service, pages: [pageURL.absoluteString: html], imageLoader: { _, _ in
            imageAttempts += 1
            throw BatchCollectorTestError.unexpectedImage
        }).collect()

        #expect(!finished.collectionComplete)
        #expect(finished.found == 0)
        #expect(imageAttempts == 0)
        #expect(service.reviewRequests.count == 1)
        #expect(try fixture.context.fetchCount(FetchDescriptor<ExamQuestion>()) == 0)
        #expect(try fixture.context.fetchCount(FetchDescriptor<StoredImage>()) == 0)
    }

    @Test func aMalformedReviewCannotSaveAnyQuestionOrDownloadImages() async throws {
        let fixture = try BatchCollectorFixture(sources: [pageURL.absoluteString])
        defer { fixture.removeFiles() }
        let document = PaperDocument(html: paperHTML, url: pageURL)
        let response = try selection(questions: [range("17", in: document, marker: "有机物甲"), range("18", in: document, marker: "有机物乙")])
        let service = BatchCollectorService([response], reviewReplies: [#"{"items":[]}"#])
        var imageAttempts = 0
        let collector = fixture.collector(service: service, pages: [pageURL.absoluteString: paperHTML], imageLoader: { _, _ in
            imageAttempts += 1
            throw BatchCollectorTestError.unexpectedImage
        })

        await #expect(throws: CompilationQuestionReview.ParseError.self) { try await collector.collect() }

        #expect(service.requests.count == 2)
        #expect(service.reviewRequests.count == 1)
        #expect(imageAttempts == 0)
        #expect(fixture.compilation.papers.first?.collectionComplete == false)
        #expect(try fixture.context.fetchCount(FetchDescriptor<ExamQuestion>()) == 0)
        #expect(try fixture.context.fetchCount(FetchDescriptor<StoredImage>()) == 0)
    }

    @Test func aFailedReviewRequestCannotSaveTheSelectedQuestion() async throws {
        let fixture = try BatchCollectorFixture(sources: [pageURL.absoluteString])
        defer { fixture.removeFiles() }
        let response = try selection(questions: [range("17", in: PaperDocument(html: paperHTML, url: pageURL), marker: "有机物甲")])
        let service = BatchCollectorService([response], reviewReplies: [])
        let collector = fixture.collector(service: service, pages: [pageURL.absoluteString: paperHTML])

        await #expect(throws: BatchCollectorTestError.self) { try await collector.collect() }

        #expect(service.reviewRequests.count == 1)
        #expect(fixture.compilation.sortedQuestions.isEmpty)
        #expect(try fixture.context.fetchCount(FetchDescriptor<StoredImage>()) == 0)
    }

    @Test func refreshingACompleteQuestionReplacesItsEquallyCompleteText() async throws {
        let fixture = try BatchCollectorFixture(sources: [pageURL.absoluteString])
        defer { fixture.removeFiles() }
        let original = ExamQuestion(paperTitle: fixture.paper.title, year: fixture.paper.year, number: "17", index: 0)
        original.content = "旧版题干，用户要求重新获取。"
        original.status = .complete
        fixture.context.insert(original)
        original.compilation = fixture.compilation
        try fixture.context.save()
        let originalID = original.id
        let html = "<html><head><title>2025 北京卷化学第 17 题</title></head><body><p>17．更新后的有机物甲实验题干，含全部条件。</p></body></html>"
        let response = try selection(questions: [range("17", in: PaperDocument(html: html, url: pageURL), marker: "更新后的有机物甲")])
        let service = BatchCollectorService([response])

        let finished = try await fixture.collector(service: service, pages: [pageURL.absoluteString: html], onlyNumber: "17").collect()

        #expect(finished.found == 1)
        #expect(service.requests.count == 2)
        #expect(service.reviewRequests.count == 1)
        #expect(service.requests.allSatisfy { !$0.webSearch })
        let saved = try #require(ModelContext(fixture.container).fetch(FetchDescriptor<ExamQuestion>()).first)
        #expect(saved.id == originalID)
        #expect(saved.status == .complete)
        #expect(saved.content.contains("更新后的有机物甲"))
        #expect(!saved.content.contains("旧版题干"))
        #expect(saved.sourceURL == pageURL.absoluteString)
    }

    @Test func aRefreshWithMissingImagesKeepsTheOldCompleteQuestionAndAssets() async throws {
        let fixture = try BatchCollectorFixture(sources: [pageURL.absoluteString])
        defer { fixture.removeFiles() }
        let original = ExamQuestion(paperTitle: fixture.paper.title, year: fixture.paper.year, number: "17", index: 0)
        original.status = .complete
        original.sourceURL = "https://example.org/previous-original"
        fixture.context.insert(original)
        original.compilation = fixture.compilation
        let originalImage = StoredImage(data: Data([1, 2, 3, 4]), contentType: "image/png")
        fixture.context.insert(originalImage)
        originalImage.question = original
        original.content = "已完整保存的题干 ![](sa-asset:\(originalImage.id.uuidString))"
        let previousContent = original.content
        let previousImageID = originalImage.id
        try fixture.context.save()
        let response = try selection(questions: [range("17", in: PaperDocument(html: paperHTML, url: pageURL), marker: "有机物甲")])
        let service = BatchCollectorService([response, #"{"sources":[]}"#])
        var imageAttempts = 0

        _ = try await fixture.collector(
            service: service, pages: [pageURL.absoluteString: paperHTML], onlyNumber: "17",
            imageLoader: { _, _ in imageAttempts += 1; throw BatchCollectorTestError.unexpectedImage }
        ).collect()

        #expect(imageAttempts == 1)
        #expect(service.requests.filter(\.webSearch).count <= 1)
        let reloaded = ModelContext(fixture.container)
        let saved = try #require(reloaded.fetch(FetchDescriptor<ExamQuestion>()).first)
        #expect(try reloaded.fetchCount(FetchDescriptor<ExamQuestion>()) == 1)
        #expect(saved.id == original.id)
        #expect(saved.status == .complete)
        #expect(saved.content == previousContent)
        #expect(saved.sourceURL == "https://example.org/previous-original")
        #expect(saved.images?.map(\.id) == [previousImageID])
        #expect(saved.images?.first?.data == Data([1, 2, 3, 4]))
    }

    @Test func twoDirectoriesSharingASuccessfulDetailDoNotFailOrRepeatRequests() async throws {
        let fixture = try BatchCollectorFixture(sources: [pageURL.absoluteString])
        defer { fixture.removeFiles() }
        let firstURL = URL(string: "https://example.org/chapter-a")!
        let secondURL = URL(string: "https://example.org/chapter-b")!
        let detailURL = URL(string: "https://example.org/shared-q17")!
        let rootHTML = "<html><head><title>2025 北京卷化学完整目录</title></head><body><p>全部试题目录</p><p><a href=\"/chapter-a\">有机部分目录甲</a></p><p><a href=\"/chapter-b\">有机部分目录乙</a></p></body></html>"
        let firstHTML = "<html><head><title>2025 北京卷化学有机目录甲</title></head><body><p><a href=\"/shared-q17\">第 17 题有机大题</a></p></body></html>"
        let secondHTML = "<html><head><title>2025 北京卷化学有机目录乙</title></head><body><p><a href=\"/shared-q17\">同一道第 17 题有机大题</a></p></body></html>"
        let detailHTML = "<html><head><title>2025 北京卷化学第 17 题</title></head><body><p>17．共享详情中的有机物甲实验原题。</p></body></html>"
        let rootDocument = PaperDocument(html: rootHTML, url: pageURL)
        let firstDocument = PaperDocument(html: firstHTML, url: firstURL)
        let secondDocument = PaperDocument(html: secondHTML, url: secondURL)
        let rootReply = selection(links: rootDocument.links.map { ["source_id": "S1", "link_id": .string($0.id)] })
        let firstReply = selection(links: firstDocument.links.map { ["source_id": "S2", "link_id": .string($0.id)] })
        let detailReply = try selection(questions: [range("17", in: PaperDocument(html: detailHTML, url: detailURL), source: "S3", marker: "共享详情")])
        let secondReply = selection(links: secondDocument.links.map { ["source_id": "S4", "link_id": .string($0.id)] })
        let service = BatchCollectorService([rootReply, firstReply, detailReply, secondReply])

        let finished = try await fixture.collector(service: service, pages: [
            pageURL.absoluteString: rootHTML, firstURL.absoluteString: firstHTML,
            secondURL.absoluteString: secondHTML, detailURL.absoluteString: detailHTML,
        ]).collect()

        #expect(finished.collectionComplete)
        #expect(finished.state == .done)
        #expect(finished.found == 1)
        #expect(service.requests.count == 5)
        #expect(service.reviewRequests.count == 1)
        #expect(service.requests.allSatisfy { !$0.webSearch && $0.tools.isEmpty })
        #expect(fixture.downloads == [pageURL, firstURL, detailURL, secondURL])
        #expect(fixture.downloads.filter { $0 == detailURL }.count == 1)
        #expect(fixture.compilation.sortedQuestions.map(\.number) == ["17"])
    }

    @Test func aCompletedDirectoryChildMustBeRecheckedBeforeItCanCompleteTheWholePaper() async throws {
        let detailURL = URL(string: "https://example.org/question-only-q17")!
        let fixture = try BatchCollectorFixture(sources: [pageURL.absoluteString, detailURL.absoluteString])
        defer { fixture.removeFiles() }
        let directoryHTML = "<html><head><title>2025 北京卷化学部分目录</title></head><body><p>只展示了部分题目，目录尚不完整。</p><p><a href=\"/question-only-q17\">第 17 题有机大题</a></p></body></html>"
        let detailHTML = "<html><head><title>2025 北京卷化学第 17 题</title></head><body><p>17．有机物甲的一道独立详情题干。</p></body></html>"
        let directoryDocument = PaperDocument(html: directoryHTML, url: pageURL)
        let link = try #require(directoryDocument.links.first { $0.url == detailURL.absoluteString })
        let directoryReply = selection(links: [["source_id": "S1", "link_id": .string(link.id)]], complete: false)
        let detailReply = try selection(questions: [range("17", in: PaperDocument(html: detailHTML, url: detailURL), source: "S2", marker: "有机物甲")])
        let standaloneReply = selection(complete: false)
        let service = BatchCollectorService([directoryReply, detailReply, standaloneReply, #"{"sources":[]}"#])

        let finished = try await fixture.collector(service: service, pages: [
            pageURL.absoluteString: directoryHTML, detailURL.absoluteString: detailHTML,
        ]).collect()

        #expect(!finished.collectionComplete)
        #expect(finished.state == .failed)
        #expect(finished.found == 1)
        #expect(service.requests.count == 5)
        #expect(service.reviewRequests.count == 1)
        #expect(service.requests.map(\.webSearch) == [false, false, false, false, true])
        #expect(service.requests.allSatisfy { $0.tools.isEmpty })
        #expect(fixture.downloads == [pageURL, detailURL])
        #expect(fixture.downloads.filter { $0 == detailURL }.count == 1)
        let saved = try #require(fixture.compilation.sortedQuestions.first)
        #expect(saved.number == "17")
        #expect(saved.status == .complete)
        #expect(saved.content.contains("有机物甲"))
    }

    @Test func directoryBatchesIncludeEveryLinkExactlyOnce() {
        let links = (1...30).map { "<p><a href=\"/question/\($0)\">北京卷化学第 \($0) 题的完整题目和答案</a></p>" }.joined()
        let document = PaperDocument(html: "<html><body><h1>北京卷化学目录</h1>\(links)</body></html>", url: pageURL)

        let batches = CompilationBatchCollector.pageBatches(document, limit: 220)
        let selectedLinks = batches.flatMap(\.links)

        #expect(batches.count > 1)
        #expect(document.links.count == 30)
        #expect(selectedLinks.map(\.id) == document.links.map(\.id))
        #expect(Set(selectedLinks.map(\.id)).count == selectedLinks.count)
        #expect(Set(batches.flatMap(\.blocks).map(\.id)) == Set(document.blocks.map(\.id)))
        #expect(batches.contains { $0.blocks.isEmpty && !$0.links.isEmpty })
    }

    @Test func questionBoundariesKeepAllSubquestionsInTheSameBatch() throws {
        let html = """
        <html><body><h1>北京卷化学试卷</h1>
        <p>17．有机物甲的合成过程如下，请根据实验条件回答。</p>
        <p>（1）第一问：写出起始物的名称，并解释判断依据。</p>
        <p>（2）最后一问：写出完整的反应方程式。</p>
        <p>18．有机物乙的性质研究，请回答以下问题。</p>
        <p>（1）说明实验结论及理由。</p></body></html>
        """
        let document = PaperDocument(html: html, url: pageURL)
        let start = try #require(document.blocks.firstIndex { $0.text.hasPrefix("17．") })
        let next = try #require(document.blocks.firstIndex { $0.text.hasPrefix("18．") })
        let expected = Set(document.blocks[start..<next].map(\.id))

        let batches = CompilationBatchCollector.batches(document.blocks, limit: 35)

        #expect(batches.count > 1)
        #expect(batches.contains { expected.isSubset(of: Set($0.map(\.id))) })
        #expect(batches.filter { !$0.map(\.id).filter(expected.contains).isEmpty }.count == 1)
    }

    @Test func readingPassageAndQuestionsEighteenThroughTwentyStayTogether() throws {
        let html = """
        <html><body><h1>2025 年语文试卷</h1>
        <p>阅读下面的材料，完成 18～20 题。</p>
        <p>这是一段所有小题都必须使用的完整阅读材料，不能只保留小题。</p>
        <p>18．概括材料中的主要内容。</p>
        <p>19．解释画线句子的含义。</p>
        <p>20．结合全文分析作者的观点。</p>
        <p>21．另一个独立的语言文字运用题。</p></body></html>
        """
        let document = PaperDocument(html: html, url: pageURL)
        let start = try #require(document.blocks.firstIndex { $0.text.contains("18～20") })
        let next = try #require(document.blocks.firstIndex { $0.text.hasPrefix("21．") })
        let expected = Set(document.blocks[start..<next].map(\.id))

        let batches = CompilationBatchCollector.batches(document.blocks, limit: 30)

        #expect(batches.contains { expected.isSubset(of: Set($0.map(\.id))) })
        #expect(batches.filter { !$0.map(\.id).filter(expected.contains).isEmpty }.count == 1)
    }

    @Test func lowerStepNumbersAndDecimalValuesDoNotSplitAMainQuestion() throws {
        let document = PaperDocument(html: """
        <p>17．完成以下实验并回答问题。</p>
        <p>1. 加入适量的水。</p><p>2. 加热至指定温度。</p>
        <p>18.5 mL 的溶液中溶质的物质的量是多少？</p>
        <p>18．另一道独立实验题。</p>
        """, url: pageURL)
        let nextQuestion = try #require(document.blocks.last)

        let batches = CompilationBatchCollector.batches(document.blocks, limit: 12)

        #expect(batches.count == 2)
        #expect(batches.first == Array(document.blocks.dropLast()))
        #expect(batches.last == [nextQuestion])
    }

    @Test func unnumberedDocumentsRetainEveryBlockAcrossBatches() {
        let paragraphs = (1...12).map { "<p>这是第\($0)段正文，内容没有试题编号但必须完整交给模型检查。</p>" }.joined()
        let document = PaperDocument(html: "<html><body>\(paragraphs)</body></html>", url: pageURL)

        let batches = CompilationBatchCollector.batches(document.blocks, limit: 65)

        #expect(batches.count > 1)
        #expect(batches.allSatisfy { !$0.isEmpty })
        #expect(Set(batches.flatMap { $0 }.map(\.id)) == Set(document.blocks.map(\.id)))
        #expect(batches.first?.first?.id == document.blocks.first?.id)
        #expect(batches.last?.last?.id == document.blocks.last?.id)
    }

    @Test func anOversizedSingleParagraphIsPreservedInFull() throws {
        let original = String(repeating: "必须保留完整阅读材料。", count: 100)
        let document = PaperDocument(html: "<html><body><p>\(original)</p></body></html>", url: pageURL)

        let batches = CompilationBatchCollector.pageBatches(document, limit: 80)

        let only = try #require(batches.first)
        #expect(batches.count == 1)
        #expect(only.oversized)
        #expect(only.blocks == document.blocks)
        #expect(only.blocks.first?.text == original)
    }
}
