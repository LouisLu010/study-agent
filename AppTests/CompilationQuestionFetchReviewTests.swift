import Foundation
import StudyKit
import SwiftData
import Testing
@testable import StudyAgent

@MainActor
private final class QuestionFetchReviewFixture {
    let container: ModelContainer
    let context: ModelContext
    let compilation: Compilation
    let question: ExamQuestion

    init() throws {
        container = try ModelContainer(
            for: Compilation.self, ExamQuestion.self, StoredImage.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
        context = ModelContext(container)
        compilation = Compilation(request: "北京卷化学有机题")
        context.insert(compilation)
        question = ExamQuestion(paperTitle: "2025 年北京卷化学", year: "2025", number: "17", index: 0)
        question.content = "旧版有机反应题干。"
        question.status = .complete
        context.insert(question)
        question.compilation = compilation
    }

    func image(bytes: String) -> StoredImage {
        let image = StoredImage(data: Data(bytes.utf8), contentType: "image/png")
        context.insert(image)
        image.question = question
        return image
    }
}

@MainActor
@Suite struct CompilationQuestionFetchReviewTests {
    private let pageURL = URL(string: "https://example.org/new-question")!

    private func attempt(html: String, images: [Int: (Data, String)] = [:]) throws -> QuestionFetch.Attempt {
        let result = try QuestionExtractor.extract(
            html: html, baseURL: pageURL, anchor: "新的有机反应条件", lastAnchor: ""
        ).get()
        return QuestionFetch.Attempt(url: pageURL, result: result, images: images, viaFetch: false)
    }

    @Test func fetchingAnEmptyAnswerClearsTheOldWebsiteAnswerAndSourceLabel() throws {
        let fixture = try QuestionFetchReviewFixture()
        let oldImage = fixture.image(bytes: "旧网站答案图")
        fixture.question.answer = "旧网站答案 ![](sa-asset:\(oldImage.id.uuidString))"
        fixture.question.answerKind = .site
        fixture.question.answerSite = "旧题库"
        let downloaded = try attempt(html: "<p>17．新的有机反应条件齐全，请写出产物。</p>")
        #expect(downloaded.result.answer.isEmpty)

        QuestionFetch.apply(downloaded, to: fixture.question, context: fixture.context)
        try fixture.context.save()

        let context = ModelContext(fixture.container)
        let saved = try #require(context.fetch(FetchDescriptor<ExamQuestion>()).first)
        #expect(saved.answer.isEmpty)
        #expect(saved.answerKind == .none)
        #expect(saved.answerSite.isEmpty)
        #expect(saved.content.contains("新的有机反应条件"))
        #expect(saved.sourceURL == pageURL.absoluteString)
        #expect(try context.fetchCount(FetchDescriptor<StoredImage>()) == 0)
    }

    @Test func fetchingPreservesAIAnswerImagesAndReplacesOnlyTheOldQuestionImages() throws {
        let fixture = try QuestionFetchReviewFixture()
        let oldQuestionImage = fixture.image(bytes: "旧题图")
        let aiAnswerImage = fixture.image(bytes: "AI 答案图")
        let oldQuestionImageID = oldQuestionImage.id
        let aiAnswerImageID = aiAnswerImage.id
        fixture.question.content = "旧题干 ![](sa-asset:\(oldQuestionImageID.uuidString))"
        let originalAnswer = "已写好的 AI 解析 ![](sa-asset:\(aiAnswerImageID.uuidString))"
        fixture.question.answer = originalAnswer
        fixture.question.answerKind = .ai
        fixture.question.answerSite = ""
        let downloaded = try attempt(
            html: "<p>17．新的有机反应条件齐全，请根据原图写出产物。<img src=\"/new.png\">【答案】新的题库答案。</p>",
            images: [0: (Data("新题图".utf8), "image/png")]
        )
        #expect(!downloaded.result.answer.isEmpty)

        QuestionFetch.apply(downloaded, to: fixture.question, context: fixture.context)
        try fixture.context.save()

        let context = ModelContext(fixture.container)
        let saved = try #require(context.fetch(FetchDescriptor<ExamQuestion>()).first)
        let images = try context.fetch(FetchDescriptor<StoredImage>())
        let newImage = try #require(images.first { $0.data == Data("新题图".utf8) })
        #expect(images.count == 2)
        #expect(images.contains { $0.id == aiAnswerImageID && $0.data == Data("AI 答案图".utf8) })
        #expect(!images.contains { $0.id == oldQuestionImageID })
        #expect(saved.answer == originalAnswer)
        #expect(saved.answerKind == .ai)
        #expect(saved.answerSite.isEmpty)
        #expect(saved.content.contains("sa-asset:\(newImage.id.uuidString)"))
        #expect(!saved.content.contains(oldQuestionImageID.uuidString))
        #expect(!saved.content.contains(aiAnswerImageID.uuidString))
        #expect(Set(saved.images?.map(\.id) ?? []) == Set([aiAnswerImageID, newImage.id]))
        #expect(saved.status == .complete)
    }

    @Test func applyingFetchedContentInvalidatesReviewAndEveryPDFCacheField() throws {
        for wasRejected in [false, true] {
            let fixture = try QuestionFetchReviewFixture()
            CompilationQuestionReviewer.markReviewed(fixture.question)
            fixture.question.reviewRejected = wasRejected
            fixture.question.reviewNote = wasRejected ? "旧内容不是题目" : "旧复核说明"
            fixture.compilation.pdfData = Data("旧 PDF".utf8)
            fixture.compilation.pdfGeneratedAt = .now
            fixture.compilation.pdfPending = true
            #expect(CompilationQuestionReviewer.hasCurrentReview(fixture.question))
            let downloaded = try attempt(html: "<p>17．新的有机反应条件齐全，请写出产物。</p>")

            QuestionFetch.apply(downloaded, to: fixture.question, context: fixture.context)
            try fixture.context.save()

            let context = ModelContext(fixture.container)
            let saved = try #require(context.fetch(FetchDescriptor<ExamQuestion>()).first)
            let compilation = try #require(context.fetch(FetchDescriptor<Compilation>()).first)
            #expect(saved.reviewFingerprint.isEmpty)
            #expect(!saved.reviewRejected)
            #expect(saved.reviewNote.isEmpty)
            #expect(!CompilationQuestionReviewer.hasCurrentReview(saved))
            #expect(compilation.pdfData == nil)
            #expect(compilation.pdfGeneratedAt == nil)
            #expect(!compilation.pdfPending)
        }
    }

    @Test func alreadyReviewedQuestionsPassTheExportGateWithoutAConfiguredModel() async throws {
        let fixture = try QuestionFetchReviewFixture()
        CompilationQuestionReviewer.markReviewed(fixture.question)
        let fingerprint = fixture.question.reviewFingerprint
        #expect(fixture.compilation.modelID == nil)
        let center = CompilationCenter()

        try await center.reviewQuestions(fixture.compilation, context: fixture.context)
        try await center.reviewQuestions(fixture.compilation, context: fixture.context)

        #expect(CompilationQuestionReviewer.isReviewed(fixture.question))
        #expect(fixture.question.reviewFingerprint == fingerprint)
        #expect(fixture.compilation.searches == 0)
        #expect(fixture.compilation.costCNY == 0)
        #expect(center.activity[fixture.compilation.id]?.isEmpty ?? true)
    }

    @Test func cachedRejectionBlocksTheExportGateEvenWithoutAConfiguredModel() async throws {
        let fixture = try QuestionFetchReviewFixture()
        CompilationQuestionReviewer.markReviewed(fixture.question)
        fixture.question.reviewRejected = true
        fixture.question.reviewNote = "原页只有导航，没有题目。"
        #expect(fixture.compilation.modelID == nil)
        #expect(CompilationQuestionReviewer.hasCurrentReview(fixture.question))
        let center = CompilationCenter()

        for _ in 0..<2 {
            do {
                try await center.reviewQuestions(fixture.compilation, context: fixture.context)
                Issue.record("已缓存的拒绝结果必须阻止导出。")
            } catch let error as CompilationError {
                guard case let .unverifiedQuestions(labels) = error else {
                    Issue.record("应使用缓存拒绝导出，不能尝试查找模型。")
                    continue
                }
                #expect(labels.contains(fixture.question.label))
            }
        }

        #expect(fixture.question.reviewRejected)
        #expect(fixture.compilation.pdfData == nil)
        #expect(fixture.compilation.pdfGeneratedAt == nil)
        #expect(!fixture.compilation.pdfPending)
        #expect(fixture.compilation.searches == 0)
        #expect(fixture.compilation.costCNY == 0)
        #expect(center.activity[fixture.compilation.id]?.isEmpty ?? true)
    }
}
