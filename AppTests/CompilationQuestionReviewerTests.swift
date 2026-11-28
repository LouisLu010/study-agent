import Foundation
import StudyKit
import SwiftData
import Testing
@testable import StudyAgent

private enum QuestionReviewerTestError: Error {
    case scriptExhausted
}

private final class QuestionReviewerService: ChatService, @unchecked Sendable {
    private let lock = NSLock()
    private var replies: [String]
    private var captured: [ChatRequest] = []
    private let beforeReply: (@MainActor @Sendable () -> Void)?

    init(_ replies: [String], beforeReply: (@MainActor @Sendable () -> Void)? = nil) {
        self.replies = replies
        self.beforeReply = beforeReply
    }

    var requests: [ChatRequest] {
        lock.lock()
        defer { lock.unlock() }
        return captured
    }

    func streamChat(_ request: ChatRequest) -> AsyncThrowingStream<ChatStreamEvent, any Error> {
        lock.lock()
        captured.append(request)
        let reply = replies.isEmpty ? nil : replies.removeFirst()
        lock.unlock()
        let beforeReply = beforeReply
        return AsyncThrowingStream { continuation in
            Task { @MainActor in
                beforeReply?()
                guard let reply else {
                    continuation.finish(throwing: QuestionReviewerTestError.scriptExhausted)
                    return
                }
                continuation.yield(.text(reply))
                continuation.finish()
            }
        }
    }
}

@MainActor
private final class QuestionReviewerFixture {
    let container: ModelContainer
    let context: ModelContext
    let compilation: Compilation
    let paper: PaperPlan

    init() throws {
        container = try ModelContainer(
            for: Compilation.self, ExamQuestion.self, StoredImage.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
        context = ModelContext(container)
        compilation = Compilation(request: "2025 年北京卷化学有机大题")
        compilation.subject = .chemistry
        paper = PaperPlan(title: "2025 年北京卷化学", shortTitle: "北京卷", year: "2025", collectionComplete: true)
        compilation.papers = [paper]
        context.insert(compilation)
    }

    func question(_ content: String = "17．请写出反应产物。", answer: String = "", number: String = "17") -> ExamQuestion {
        let question = ExamQuestion(paperTitle: paper.title, year: paper.year, number: number, index: compilation.questions?.count ?? 0)
        question.content = content
        question.answer = answer
        question.sourceURL = "https://example.org/paper"
        context.insert(question)
        question.compilation = compilation
        return question
    }

    func image(for question: ExamQuestion, bytes: String) -> StoredImage {
        let image = StoredImage(data: Data(bytes.utf8), contentType: "image/png")
        context.insert(image)
        image.question = question
        return image
    }

    func reviewer(_ service: QuestionReviewerService) -> CompilationQuestionReviewer {
        CompilationQuestionReviewer(
            session: CompilationBatchSession(
                compilation: compilation, model: ChatModel(modelID: "deepseek-flash"), service: service, log: { _, _ in }
            ),
            context: context
        )
    }
}

@MainActor
@Suite struct CompilationQuestionReviewerTests {
    private func candidate(_ question: ExamQuestion) -> CompilationQuestionReview.Candidate {
        CompilationQuestionReview.Candidate(
            id: question.id.uuidString, number: question.number, content: question.content, answer: question.answer
        )
    }

    private func item(
        _ candidate: CompilationQuestionReview.Candidate, isQuestion: Bool = true,
        question: [String]? = nil, answer: [String]? = nil, note: String = "已复核"
    ) -> JSONValue {
        [
            "id": .string(candidate.id), "is_question": .bool(isQuestion),
            "question": .array((question ?? candidate.blocks.filter { $0.origin == .question }.map(\.id)).map(JSONValue.string)),
            "answer": .array((answer ?? candidate.blocks.filter { $0.origin == .answer }.map(\.id)).map(JSONValue.string)),
            "note": .string(note),
        ]
    }

    private func response(_ items: [JSONValue]) -> String {
        JSONValue.object(["items": .array(items)]).jsonString
    }

    @Test func successfulReviewIsPersistedAndReusedWithoutAnotherRequest() async throws {
        let fixture = try QuestionReviewerFixture()
        let question = fixture.question()
        let service = QuestionReviewerService([response([item(candidate(question))])])
        let reviewer = fixture.reviewer(service)
        fixture.compilation.pdfData = Data("旧 PDF".utf8)
        fixture.compilation.pdfGeneratedAt = .now
        fixture.compilation.pdfPending = true

        try await reviewer.ensureReviewed([question])
        try await reviewer.ensureReviewed([question, question])

        #expect(service.requests.count == 1)
        #expect(service.requests.allSatisfy { !$0.webSearch && $0.tools.isEmpty })
        #expect(CompilationQuestionReviewer.isReviewed(question))
        #expect(question.reviewFingerprint.count == 64)
        #expect(fixture.compilation.pdfData == nil && fixture.compilation.pdfGeneratedAt == nil && !fixture.compilation.pdfPending)
        let saved = try #require(ModelContext(fixture.container).fetch(FetchDescriptor<ExamQuestion>()).first)
        #expect(CompilationQuestionReviewer.isReviewed(saved))
        #expect(saved.content == question.content)
    }

    @Test func manualContentAndAnswerEditsInvalidateTheFingerprint() async throws {
        let fixture = try QuestionReviewerFixture()
        let question = fixture.question()
        CompilationQuestionReviewer.markReviewed(question)
        let originalFingerprint = question.reviewFingerprint
        question.content += "\n（1）写出条件。"
        #expect(!CompilationQuestionReviewer.hasCurrentReview(question))
        let service = QuestionReviewerService([response([item(candidate(question))])])
        try await fixture.reviewer(service).ensureReviewed([question])
        #expect(CompilationQuestionReviewer.isReviewed(question))
        #expect(question.reviewFingerprint != originalFingerprint)
        question.answer = "反应条件。"
        #expect(!CompilationQuestionReviewer.hasCurrentReview(question))
        #expect(service.requests.count == 1)
    }

    @Test func rejectionIsCachedWithoutDeletingTheOriginalQuestionOrImage() async throws {
        let fixture = try QuestionReviewerFixture()
        var completedPaper = fixture.paper
        completedPaper.state = .done
        completedPaper.note = "已完成"
        fixture.compilation.papers = [completedPaper]
        fixture.compilation.status = .done
        let question = fixture.question("请登录下载")
        let image = fixture.image(for: question, bytes: "广告原图")
        question.content += "\n![](sa-asset:\(image.id))"
        let original = question.content
        let service = QuestionReviewerService([response([
            item(candidate(question), isQuestion: false, question: [], answer: [], note: "只取到了登录提示。"),
        ])])
        let reviewer = fixture.reviewer(service)

        try await reviewer.ensureReviewed([question])
        try await reviewer.ensureReviewed([question])

        #expect(service.requests.count == 1)
        #expect(question.content == original)
        #expect(question.images?.count == 1 && image.data == Data("广告原图".utf8))
        #expect(question.reviewRejected)
        #expect(question.reviewNote == "只取到了登录提示。")
        #expect(CompilationQuestionReviewer.hasCurrentReview(question))
        #expect(!CompilationQuestionReviewer.isReviewed(question))
        #expect(fixture.compilation.papers.first?.collectionComplete == false)
        #expect(fixture.compilation.papers.first?.state == .failed)
        #expect(fixture.compilation.status == .paused)
        #expect(fixture.compilation.papers.first?.note == "第 17 题未通过复核：只取到了登录提示。")
        let reloaded = ModelContext(fixture.container)
        let saved = try #require(reloaded.fetch(FetchDescriptor<ExamQuestion>()).first)
        #expect(saved.reviewRejected && CompilationQuestionReviewer.hasCurrentReview(saved))
        let savedPaper = try #require(reloaded.fetch(FetchDescriptor<Compilation>()).first?.papers.first)
        #expect(savedPaper.state == .failed && !savedPaper.collectionComplete)
        #expect(savedPaper.note.contains("只取到了登录提示"))
    }

    @Test func malformedReplyDoesNotChangeQuestionsImagesOrReviewState() async throws {
        let fixture = try QuestionReviewerFixture()
        let question = fixture.question(answer: "原答案")
        let image = fixture.image(for: question, bytes: "原图")
        question.content += "\n![](sa-asset:\(image.id))"
        let original = question.content
        let service = QuestionReviewerService(["{}"])
        fixture.compilation.pdfData = Data("已有 PDF".utf8)

        await #expect(throws: CompilationQuestionReview.ParseError.self) {
            try await fixture.reviewer(service).ensureReviewed([question])
        }

        #expect(question.content == original && question.answer == "原答案")
        #expect(question.images?.count == 1 && image.data == Data("原图".utf8))
        #expect(question.reviewFingerprint.isEmpty && !question.reviewRejected)
        #expect(fixture.compilation.pdfData == Data("已有 PDF".utf8))
    }

    @Test func separatesOriginalAnswerAndDeletesOnlyUnusedImages() async throws {
        let fixture = try QuestionReviewerFixture()
        let question = fixture.question()
        let originalImage = fixture.image(for: question, bytes: "题图原始字节")
        let answerImage = fixture.image(for: question, bytes: "答案原始字节")
        let advertisement = fixture.image(for: question, bytes: "广告图片")
        question.content = """
        17．请根据原图回答。
        ![](sa-asset:\(originalImage.id) "w=500,h=300")
        下载本卷高清答案
        ![](sa-asset:\(advertisement.id))
        答案：产物如图。
        ![](sa-asset:\(answerImage.id))
        """
        question.answerKind = .site
        question.answerSite = "原试题网站"
        let input = candidate(question)
        #expect(input.blocks.count == 6)
        let service = QuestionReviewerService([response([
            item(input, question: Array(input.blocks.prefix(2).map(\.id)), answer: Array(input.blocks.suffix(2).map(\.id))),
        ])])

        try await fixture.reviewer(service).ensureReviewed([question])

        #expect(question.content == "17．请根据原图回答。\n![](sa-asset:\(originalImage.id) \"w=500,h=300\")")
        #expect(question.answer == "答案：产物如图。\n![](sa-asset:\(answerImage.id))")
        #expect(question.answerKind == .site && question.answerSite == "原试题网站")
        #expect(Set((question.images ?? []).map(\.id)) == [originalImage.id, answerImage.id])
        #expect(originalImage.data == Data("题图原始字节".utf8) && answerImage.data == Data("答案原始字节".utf8))
        #expect(try fixture.context.fetchCount(FetchDescriptor<StoredImage>()) == 2)
        #expect(CompilationQuestionReviewer.isReviewed(question))
    }

    @Test func aiAnswerKeepsItsLabelWhileRemovingUnrelatedBlocks() async throws {
        let fixture = try QuestionReviewerFixture()
        let question = fixture.question(answer: "答案：乙。\n登录下载全文")
        question.answerKind = .ai
        let input = candidate(question)
        let answer = try #require(input.blocks.first { $0.text == "答案：乙。" })
        let service = QuestionReviewerService([response([item(input, answer: [answer.id])])])

        try await fixture.reviewer(service).ensureReviewed([question])

        #expect(question.answer == "答案：乙。")
        #expect(question.answerKind == .ai)
        #expect(question.answerSite.isEmpty)
    }

    @Test func concurrentEditDoesNotGetOverwrittenByAnOlderReview() async throws {
        let fixture = try QuestionReviewerFixture()
        let question = fixture.question()
        let service = QuestionReviewerService([response([item(candidate(question))])], beforeReply: {
            question.content = "用户刚刚修改的题干。"
        })

        await #expect(throws: CompilationQuestionReviewer.ReviewError.contentChanged) {
            try await fixture.reviewer(service).ensureReviewed([question])
        }

        #expect(question.content == "用户刚刚修改的题干。")
        #expect(question.reviewFingerprint.isEmpty)
    }

    @Test func deletionDuringReviewDoesNotRecreateTheQuestion() async throws {
        let fixture = try QuestionReviewerFixture()
        let question = fixture.question()
        try fixture.context.save()
        let service = QuestionReviewerService([response([item(candidate(question))])], beforeReply: {
            fixture.context.delete(question)
        })

        await #expect(throws: CompilationQuestionReviewer.ReviewError.contentChanged) {
            try await fixture.reviewer(service).ensureReviewed([question])
        }

        try fixture.context.save()
        #expect(try fixture.context.fetchCount(FetchDescriptor<ExamQuestion>()) == 0)
    }

    @Test func networkFailureLeavesTheQuestionReadyForRetry() async throws {
        let fixture = try QuestionReviewerFixture()
        let question = fixture.question()
        let service = QuestionReviewerService([])

        await #expect(throws: QuestionReviewerTestError.self) {
            try await fixture.reviewer(service).ensureReviewed([question])
        }

        #expect(question.reviewFingerprint.isEmpty && !question.reviewRejected)
        #expect(question.content == "17．请写出反应产物。")
    }

    @Test func differentPapersAndYearsAreReviewedSeparately() async throws {
        let fixture = try QuestionReviewerFixture()
        let first = fixture.question(number: "17")
        let second = fixture.question(number: "18")
        second.year = "2024"
        let third = fixture.question(number: "19")
        third.paperTitle = "2025 年上海卷化学"
        let service = QuestionReviewerService([first, second, third].map { response([item(candidate($0))]) })

        try await fixture.reviewer(service).ensureReviewed([first, second, third])

        #expect(service.requests.count == 3)
        #expect([first, second, third].allSatisfy(CompilationQuestionReviewer.isReviewed))
        #expect(service.requests[1].messages.first?.text.contains("年份：2024") == true)
        #expect(service.requests[2].messages.first?.text.contains("2025 年上海卷化学") == true)
    }

    @Test func batchingLimitsEightQuestionsAndKeepsOversizedQuestionsWhole() {
        let small = (1...9).map {
            CompilationQuestionReview.Candidate(id: "Q\($0)", number: String($0), content: "完整题干", answer: "")
        }
        #expect(CompilationQuestionReviewer.batches(small).map(\.count) == [8, 1])
        let large = CompilationQuestionReview.Candidate(id: "large", number: "10", content: String(repeating: "原", count: 25_000), answer: "完整答案")
        let batches = CompilationQuestionReviewer.batches([small[0], large, small[1]])
        #expect(batches.map(\.count) == [1, 1, 1])
        #expect(batches[1][0] == large)
        #expect(CompilationQuestionReviewer.batches([]).isEmpty)
    }

    @Test func emptyReviewDoesNotSendARequestAndDuplicateIDsFailLocally() async throws {
        let fixture = try QuestionReviewerFixture()
        let service = QuestionReviewerService([])
        let reviewer = fixture.reviewer(service)
        #expect(try await reviewer.review([], paper: fixture.paper).isEmpty)
        let input = candidate(fixture.question())
        await #expect(throws: CompilationQuestionReviewer.ReviewError.invalidCandidates) {
            try await reviewer.review([input, input], paper: fixture.paper)
        }
        #expect(service.requests.isEmpty)
    }
}
