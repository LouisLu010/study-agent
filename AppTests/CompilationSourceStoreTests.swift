import Foundation
import StudyKit
import SwiftData
import Testing
@testable import StudyAgent

@MainActor
@Suite struct CompilationSourceStoreTests {
    private func temporaryDirectory() -> URL {
        FileManager.default.temporaryDirectory.appending(path: "compilation-sources-" + UUID().uuidString, directoryHint: .isDirectory)
    }

    private func entries(in directory: URL) -> [URL] {
        ((try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? [])
            .filter { $0.pathExtension == "source" }
    }

    @Test func storesOriginalHTMLAndReusesItAcrossInstances() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        var requests: [URL] = []
        let html = "<article><p>第 17 题</p><img src=\"/原图.png\"></article>"
        let first = CompilationSourceStore(directory: directory) { url in
            requests.append(url)
            return html
        }
        let firstURL = try #require(URL(string: "https://example.com/paper?year=2026#q17"))
        let secondURL = try #require(URL(string: "https://example.com/paper?year=2026#q18"))
        #expect(try await first.html(for: firstURL) == html)
        #expect(try await first.html(for: secondURL) == html)
        let restarted = CompilationSourceStore(directory: directory) { url in
            requests.append(url)
            return "不应下载"
        }
        #expect(try await restarted.html(for: firstURL) == html)
        #expect(requests.count == 1)
        #expect(requests.first?.fragment == nil)
        let file = try #require(entries(in: directory).first)
        #expect(file.deletingPathExtension().lastPathComponent.count == 64)
    }

    @Test func queryParametersKeepDifferentPapersSeparate() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        var calls = 0
        let store = CompilationSourceStore(directory: directory) { url in
            calls += 1
            return "<p>" + (url.query ?? "") + "</p>"
        }
        let a = try #require(URL(string: "https://example.com/paper?id=1"))
        let b = try #require(URL(string: "https://example.com/paper?id=2"))
        #expect(try await store.html(for: a) == "<p>id=1</p>")
        #expect(try await store.html(for: b) == "<p>id=2</p>")
        #expect(calls == 2)
        #expect(entries(in: directory).count == 2)
    }

    @Test func invalidatingAFragmentRefreshesTheOriginalPage() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        var calls = 0
        let store = CompilationSourceStore(directory: directory) { _ in
            calls += 1
            return calls == 1 ? "<p>临时提示</p>" : "<p>完整试卷</p>"
        }
        let first = try #require(URL(string: "https://example.com/paper#q17"))
        let second = try #require(URL(string: "https://example.com/paper#q18"))
        #expect(try await store.html(for: first) == "<p>临时提示</p>")
        store.invalidate(for: second)
        #expect(try await store.html(for: first) == "<p>完整试卷</p>")
        #expect(calls == 2)
    }

    @Test func rejectsLocalURLsAndEmbeddedCredentialsBeforeDownloading() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        var calls = 0
        let store = CompilationSourceStore(directory: directory) { _ in calls += 1; return "<p>内容</p>" }
        for raw in ["file:///tmp/paper.html", "ftp://example.com/paper", "https://user:password@example.com/paper", "https://@example.com/paper"] {
            let url = try #require(URL(string: raw))
            await #expect(throws: CompilationSourceStore.StoreError.self) {
                try await store.html(for: url)
            }
        }
        #expect(calls == 0)
        #expect(entries(in: directory).isEmpty)
    }

    @Test func failedAndCancelledDownloadsAreNotStored() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = try #require(URL(string: "https://example.com/paper"))
        var calls = 0
        let failing = CompilationSourceStore(directory: directory) { _ in
            calls += 1
            if calls == 1 { throw URLError(.timedOut) }
            return "<p>重试成功</p>"
        }
        await #expect(throws: URLError.self) { try await failing.html(for: url) }
        #expect(entries(in: directory).isEmpty)
        #expect(try await failing.html(for: url) == "<p>重试成功</p>")
        #expect(calls == 2)

        let cancelledURL = try #require(URL(string: "https://example.com/cancelled"))
        let cancelled = CompilationSourceStore(directory: directory) { _ in
            withUnsafeCurrentTask { $0?.cancel() }
            return "<p>取消后的返回值</p>"
        }
        let task = Task { try await cancelled.html(for: cancelledURL) }
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(entries(in: directory).count == 1)
    }

    @Test func alreadyCancelledRequestDoesNotDownload() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        var calls = 0
        let store = CompilationSourceStore(directory: directory) { _ in calls += 1; return "<p>内容</p>" }
        let url = try #require(URL(string: "https://example.com/paper"))
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await store.html(for: url)
        }
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(calls == 0)
    }

    @Test func corruptOrMismatchedCacheIsDownloadedAgain() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        var calls = 0
        let store = CompilationSourceStore(directory: directory) { _ in calls += 1; return "<p>原文</p>" }
        let url = try #require(URL(string: "https://example.com/paper"))
        _ = try await store.html(for: url)
        let file = try #require(entries(in: directory).first)
        try Data("损坏的缓存".utf8).write(to: file)
        #expect(try await store.html(for: url) == "<p>原文</p>")
        #expect(calls == 2)

        let saved = try Data(contentsOf: file)
        var entry = try #require(PropertyListSerialization.propertyList(from: saved, format: nil) as? [String: Any])
        entry["url"] = "https://example.com/another-paper"
        try PropertyListSerialization.data(fromPropertyList: entry, format: .binary, options: 0).write(to: file)
        #expect(try await store.html(for: url) == "<p>原文</p>")
        #expect(calls == 3)

        entry = try #require(PropertyListSerialization.propertyList(from: Data(contentsOf: file), format: nil) as? [String: Any])
        entry["html"] = "<p>被篡改的原文</p>"
        try PropertyListSerialization.data(fromPropertyList: entry, format: .binary, options: 0).write(to: file)
        #expect(try await store.html(for: url) == "<p>原文</p>")
        #expect(calls == 4)
    }

    @Test func evictsOldestPagesWithinDiskCapacity() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        var calls = 0
        let capacity = 2500
        let store = CompilationSourceStore(directory: directory, download: { _ in
            calls += 1
            return "<p>" + String(repeating: "a", count: 1500) + "</p>"
        }, capacityBytes: capacity)
        let old = try #require(URL(string: "https://example.com/old"))
        let new = try #require(URL(string: "https://example.com/new"))
        _ = try await store.html(for: old)
        let oldFile = try #require(entries(in: directory).first)
        try FileManager.default.setAttributes([.modificationDate: Date.distantPast], ofItemAtPath: oldFile.path)
        _ = try await store.html(for: new)
        #expect(entries(in: directory).count == 1)
        let bytes = try entries(in: directory).reduce(0) { try $0 + Data(contentsOf: $1).count }
        #expect(bytes <= capacity)
        _ = try await store.html(for: new)
        #expect(calls == 2)
        _ = try await store.html(for: old)
        #expect(calls == 3)
    }

    @Test func oversizedOrEmptyPagesAreNotStored() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = try #require(URL(string: "https://example.com/paper"))
        let oversized = CompilationSourceStore(directory: directory) { _ in String(repeating: "a", count: PageFetcher.maxHTMLBytes + 1) }
        await #expect(throws: PageFetcher.FetchError.self) { try await oversized.html(for: url) }
        #expect(entries(in: directory).isEmpty)
        let empty = CompilationSourceStore(directory: directory) { _ in " \n" }
        #expect(try await empty.html(for: url) == " \n")
        #expect(entries(in: directory).isEmpty)
    }

    @Test func unwritableCacheDoesNotDiscardDownloadedPage() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        // 路径是一个文件，不能在下面创建缓存目录。
        try Data("occupied".utf8).write(to: directory)
        let store = CompilationSourceStore(directory: directory) { _ in "<p>仍可使用原文</p>" }
        let url = try #require(URL(string: "https://example.com/paper"))
        #expect(try await store.html(for: url) == "<p>仍可使用原文</p>")
    }
}

@MainActor
@Suite struct CompilationReuseTests {
    private func container() throws -> ModelContainer {
        try ModelContainer(
            for: Compilation.self, ExamQuestion.self, StoredImage.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
    }

    private func compilation(_ request: String, subject: Subject = .chemistry, context: ModelContext) -> Compilation {
        let value = Compilation(request: request)
        value.subject = subject
        context.insert(value)
        return value
    }

    private func question(in compilation: Compilation, paper: PaperPlan, number: String = "17", context: ModelContext) -> ExamQuestion {
        let question = ExamQuestion(paperTitle: paper.title, year: paper.year, number: number, index: compilation.questions?.count ?? 0)
        question.content = "合成路线与完整问题。"
        question.sourceURL = "https://example.com/paper#q" + number
        question.candidateURLs = ["https://example.com/paper#q" + number, "https://example.com/alternate"]
        question.status = .complete
        context.insert(question)
        question.compilation = compilation
        return question
    }

    @Test func copiesImagesIndependentlyAndSurvivesDeletingSource() throws {
        let container = try container()
        let context = ModelContext(container)
        var paper = PaperPlan(title: "2026 北京卷化学", shortTitle: "北京卷", year: "2026", sourceURLs: ["https://example.com/paper"], collectionComplete: true)
        paper.found = 1
        let source = compilation("有机大题", context: context)
        source.papers = [paper]
        let sourceQuestion = question(in: source, paper: paper, context: context)
        let picture = StoredImage(data: Data("原图数据".utf8), contentType: "image/png")
        context.insert(picture)
        picture.question = sourceQuestion
        sourceQuestion.content = "题干 ![](sa-asset:\(picture.id.uuidString.lowercased()) \"w=500,h=300\")"
        sourceQuestion.answer = "解析 ![](sa-asset:\(picture.id.uuidString))"
        sourceQuestion.answerKind = .site
        sourceQuestion.answerSite = "题目来源"
        sourceQuestion.anchor = "题干开头"
        sourceQuestion.lastAnchor = "最后一问"
        let target = compilation("有机大题", context: context)
        target.papers = [paper]
        target.pdfData = Data("旧 PDF".utf8)
        target.pdfGeneratedAt = .now
        target.pdfPending = true
        let candidate = try #require(CompilationReuse.candidates(for: paper, in: target, context: context).first)
        #expect(candidate.canReuseAll)
        let copied = try #require(CompilationReuse.copy(candidate, into: target, paper: paper, context: context).first)
        let image = try #require(copied.images?.first)
        #expect(copied.id != sourceQuestion.id)
        #expect(image.id != picture.id)
        #expect(image.data == picture.data)
        #expect(image.contentType == picture.contentType)
        #expect(copied.content.contains(image.id.uuidString))
        #expect(copied.answer.contains(image.id.uuidString))
        #expect(!copied.content.lowercased().contains(picture.id.uuidString.lowercased()))
        #expect(copied.content.contains("w=500,h=300"))
        #expect(copied.answerKind == .site)
        #expect(copied.answerSite == sourceQuestion.answerSite)
        #expect(copied.anchor == sourceQuestion.anchor)
        #expect(copied.lastAnchor == sourceQuestion.lastAnchor)
        #expect(target.pdfData == nil && target.pdfGeneratedAt == nil && !target.pdfPending)
        let targetID = target.id
        let copiedImageID = image.id
        try context.save()
        context.delete(source)
        try context.save()

        let reloaded = ModelContext(container)
        let saved = try #require(reloaded.fetch(FetchDescriptor<Compilation>()).first { $0.id == targetID })
        let savedQuestion = try #require(saved.questions?.first)
        let savedImage = try #require(savedQuestion.images?.first)
        #expect(savedImage.id == copiedImageID)
        #expect(savedImage.data == Data("原图数据".utf8))
        #expect(savedQuestion.content.contains(copiedImageID.uuidString))
        #expect(try reloaded.fetchCount(FetchDescriptor<Compilation>()) == 1)
        #expect(try reloaded.fetchCount(FetchDescriptor<ExamQuestion>()) == 1)
        #expect(try reloaded.fetchCount(FetchDescriptor<StoredImage>()) == 1)
    }

    @Test func exactTitleYearAndSubjectAreRequired() throws {
        let context = ModelContext(try container())
        let paper = PaperPlan(title: "北京卷化学", year: "2026", sourceURLs: ["https://example.com/paper"])
        let target = compilation("目标", context: context)
        let wrongTitle = PaperPlan(title: "天津卷化学", year: paper.year, sourceURLs: paper.sourceURLs)
        let wrongYear = PaperPlan(title: paper.title, year: "2025", sourceURLs: paper.sourceURLs)
        for (sourcePaper, subject) in [(wrongTitle, Subject.chemistry), (wrongYear, .chemistry), (paper, .physics)] {
            let source = compilation("旧要求", subject: subject, context: context)
            source.papers = [sourcePaper]
            let q = question(in: source, paper: sourcePaper, context: context)
            #expect(CompilationReuse.copyQuestions([q], into: target, paper: paper, context: context).isEmpty)
        }
        #expect(try CompilationReuse.candidates(for: paper, in: target, context: context).isEmpty)
        #expect(target.questions?.isEmpty == true)
    }

    @Test func doneStateAndDifferentRequestsDoNotProveCoverage() throws {
        let context = ModelContext(try container())
        var paper = PaperPlan(title: "北京卷化学", year: "2026", sourceURLs: ["https://example.com/paper"])
        paper.state = .done
        let source = compilation("有机大题", context: context)
        source.papers = [paper]
        let q = question(in: source, paper: paper, context: context)
        let target = compilation("有机大题", context: context)
        var candidate = try #require(CompilationReuse.candidates(for: paper, in: target, context: context).first)
        #expect(!candidate.canReuseAll)
        #expect(candidate.questions.map(\.id) == [q.id])
        paper.collectionComplete = true
        paper.found = 1
        source.papers = [paper]
        candidate = try #require(CompilationReuse.candidates(for: paper, in: target, context: context).first)
        #expect(candidate.canReuseAll)
        target.request = "选择题"
        candidate = try #require(CompilationReuse.candidates(for: paper, in: target, context: context).first)
        #expect(!candidate.canReuseAll)
        #expect(candidate.questions.count == 1)
        #expect(candidate.sourceURLs == ["https://example.com/paper", "https://example.com/alternate"])
    }

    @Test func incompleteOrMissingAssetsPreventWholePaperReuse() throws {
        let context = ModelContext(try container())
        let paper = PaperPlan(title: "北京卷化学", year: "2026", sourceURLs: ["https://example.com/paper"], collectionComplete: true)
        let source = compilation("有机大题", context: context)
        source.papers = [paper]
        let complete = question(in: source, paper: paper, context: context)
        let incomplete = question(in: source, paper: paper, number: "18", context: context)
        incomplete.status = .imagesMissing
        let broken = question(in: source, paper: paper, number: "19", context: context)
        broken.content = "![](sa-asset:\(UUID().uuidString))"
        let target = compilation("有机大题", context: context)
        let candidate = try #require(CompilationReuse.candidates(for: paper, in: target, context: context).first)
        #expect(!candidate.canReuseAll)
        #expect(candidate.questions.map(\.id) == [complete.id])
        #expect(CompilationReuse.copyQuestions([incomplete, broken], into: target, paper: paper, context: context).isEmpty)
    }

    @Test func removedQuestionInvalidatesStaleCompleteCount() throws {
        let context = ModelContext(try container())
        var paper = PaperPlan(title: "北京卷化学", year: "2026", sourceURLs: ["https://example.com/paper"], collectionComplete: true)
        paper.found = 2
        let source = compilation("有机大题", context: context)
        source.papers = [paper]
        _ = question(in: source, paper: paper, context: context)
        let target = compilation("有机大题", context: context)
        let candidate = try #require(CompilationReuse.candidates(for: paper, in: target, context: context).first)
        #expect(!candidate.canReuseAll)
        #expect(candidate.questions.count == 1)
    }

    @Test func preservesCompleteQuestionsAndUpgradesIncompleteOnes() throws {
        let context = ModelContext(try container())
        let paper = PaperPlan(title: "北京卷化学", year: "2026")
        let source = compilation("有机大题", context: context)
        source.papers = [paper]
        let q1 = question(in: source, paper: paper, number: "第 17 题", context: context)
        let q2 = question(in: source, paper: paper, number: "18", context: context)
        let target = compilation("有机大题", context: context)
        let preserved = question(in: target, paper: paper, number: "17", context: context)
        preserved.content = "已经完整的题目"
        let upgraded = question(in: target, paper: paper, number: "18", context: context)
        upgraded.status = .imagesMissing
        upgraded.content = "旧的不完整原文"
        let oldImage = StoredImage(data: Data("旧图".utf8), contentType: "image/png")
        context.insert(oldImage)
        oldImage.question = upgraded
        let copied = CompilationReuse.copyQuestions([q1, q2, q2], into: target, paper: paper, context: context)
        #expect(copied.map(\.id) == [upgraded.id])
        #expect(preserved.content == "已经完整的题目")
        #expect(upgraded.content == q2.content)
        #expect(upgraded.status == .complete)
        #expect(upgraded.images?.isEmpty == true)
        #expect(target.questions?.count == 2)
        #expect(CompilationReuse.copyQuestions([q1, q2], into: target, paper: paper, context: context).isEmpty)
        try context.save()
        #expect(try context.fetchCount(FetchDescriptor<StoredImage>()) == 0)
    }

    @Test func sourceOnlyCandidateRemainsAvailableButCannotBeCopiedAsComplete() throws {
        let context = ModelContext(try container())
        let paper = PaperPlan(title: "北京卷化学", year: "2026", sourceURLs: ["file:///tmp/paper", "https://user:secret@example.com/hidden", "https://example.com/paper#q17"])
        let source = compilation("有机大题", context: context)
        source.papers = [paper]
        let target = compilation("有机大题", context: context)
        let candidate = try #require(CompilationReuse.candidates(for: paper, in: target, context: context).first)
        #expect(candidate.questions.isEmpty)
        #expect(!candidate.canReuseAll)
        #expect(candidate.sourceURLs == ["https://example.com/paper"])
        #expect(CompilationReuse.copy(candidate, into: target, paper: paper, context: context).isEmpty)
        target.subject = nil
        #expect(try CompilationReuse.candidates(for: paper, in: target, context: context).isEmpty)
    }
}
