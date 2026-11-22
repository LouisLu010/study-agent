import Foundation
import StudyKit
import SwiftData
import UIKit

/// 在设备上执行汇编的工具（见 docs/adr/0014）。一轮工具循环一个：列试卷、查一份试卷、或者整理。
/// 每次调用在"调用记录"里记一行，取到的原题直接存进汇编；结束类的工具（submit_papers、finish_paper、make_pdf）
/// 把结果留在这里，由 `CompilationCenter` 在循环结束后处理。
@MainActor
final class CompilationToolbox {
    enum Phase {
        case listing
        case paper(PaperPlan)
        case arranging
    }

    let compilation: Compilation
    let context: ModelContext
    let model: ChatModel
    let service: any ChatService
    let phase: Phase
    private let log: CompilationCenter.Logger
    /// DeepSeek 官方地址：找寻用 Search API，网站拒绝下载时用 Fetch API 读正文（同一个 Key）。
    private let deepSeek: (base: URL, key: String)?

    /// submit_papers 交上来的试卷。
    private(set) var submitted: CompilationPlanner.PaperList?
    /// finish_paper 的说明。
    private(set) var finishNote: String?
    /// 连续太多次没有新进展，App 结束了这份试卷。
    private(set) var stagnated = false
    /// 模型调用了 make_pdf。
    private(set) var pdfRequested = false
    private var progress = PaperProgress()
    /// 整理时列给模型的编号 → 题，和编号原来的顺序。
    private var arrangeIDs: [String: ExamQuestion] = [:]
    private var arrangeOrder: [String] = []

    /// DeepSeek Search API 和 Fetch API 每次成功请求的价格（美元）。
    static let deepSeekToolPriceUSD = 0.75 / 1000

    init(
        compilation: Compilation, context: ModelContext, model: ChatModel, service: any ChatService,
        phase: Phase, log: @escaping CompilationCenter.Logger
    ) {
        self.compilation = compilation
        self.context = context
        self.model = model
        self.service = service
        self.phase = phase
        self.log = log
        if let provider = model.provider,
           let base = CompilationTools.deepSeekToolsBase(kind: provider.kind, baseURL: provider.baseURL),
           let key = KeychainStore.apiKey(for: provider.id), !key.isEmpty {
            deepSeek = (base, key)
        } else {
            deepSeek = nil
        }
    }

    // MARK: - 用量

    /// 一次请求的用量记到汇编上。
    func record(_ usage: ToolLoop.Usage) {
        compilation.searches += usage.searches
        guard let price = model.price(), usage.input != nil || usage.output != nil else { return }
        compilation.costCNY += price.costCNY(
            inputTokens: usage.input ?? 0, cachedInputTokens: usage.cachedInput, outputTokens: usage.output ?? 0,
            webSearches: usage.searches, usdToCNY: AppSettingsKey.usdToCNYRate, at: usage.started
        )
    }

    func tick() {
        BackgroundKeeper.shared.tick()
    }

    // MARK: - 执行

    /// 一次调用的结果，加上这次有没有进展（读到了新网站、取到了新题）。
    private struct Step {
        var outcome: ToolLoop.Outcome
        var host: String?
        var newQuestion = false
    }

    func execute(_ call: ToolCall) async throws -> ToolLoop.Outcome {
        guard let name = CompilationTools.Name(rawValue: call.name), allowed.contains(name) else {
            log(.warning, "模型调用了这一步不能用的工具 \(call.name)")
            return ToolLoop.Outcome(["error": .string("这一步不能用 \(call.name)。可以用：\(allowed.map(\.rawValue).joined(separator: "、"))")])
        }
        let input = call.input
        let step: Step
        switch name {
        case .searchWeb: step = try await searchWeb(input)
        case .readPage: step = try await readPage(input)
        case .fetchQuestion: step = try await fetchQuestion(input)
        case .removeQuestion: step = removeQuestion(input)
        case .finishPaper: step = finishPaper(input)
        case .submitPapers: step = submitPapers(input)
        case .arrange: step = arrange(input)
        case .makePDF: step = makePDF(input)
        }
        // 查一份试卷时，连续太多次没有进展就结束（C0：用满 40 次的都在重复搜索）。
        if case .paper = phase, name != .finishPaper, !step.outcome.stop,
           progress.record(host: step.host, newQuestion: step.newQuestion) {
            stagnated = true
            log(.warning, "连续 \(CompilationTools.maxCallsWithoutProgress) 次调用没有新进展，结束这份试卷")
            return ToolLoop.Outcome(content: step.outcome.content, stop: true)
        }
        return step.outcome
    }

    private var allowed: [CompilationTools.Name] {
        let tools: [ToolDefinition] = switch phase {
        case .listing: CompilationTools.listingTools
        case .paper: CompilationTools.paperTools
        case .arranging: CompilationTools.arrangingTools
        }
        return tools.compactMap { CompilationTools.Name(rawValue: $0.name) }
    }

    private func failure(_ error: CompilationTools.ArgumentError) -> Step {
        log(.warning, "参数不对：\(error.message)")
        return Step(outcome: ToolLoop.Outcome(error.forModel))
    }

    // MARK: - 找寻

    private func searchWeb(_ input: JSONValue) async throws -> Step {
        let query: String
        switch CompilationTools.requiredString(input, "query") {
        case let .success(value): query = value
        case let .failure(error): return failure(error)
        }
        log(.search, "搜索：\(query)")
        var results: [CompilationTools.SearchResult] = []
        var problem: String?
        if let deepSeek {
            do {
                let data = try await post(deepSeek, "search", ["query": .string(String(query.prefix(128))), "count": 8], timeout: 30)
                results = CompilationTools.parseSearchAPI(data)
                compilation.searches += 1
                if !results.isEmpty { compilation.costCNY += Self.deepSeekToolPriceUSD * AppSettingsKey.usdToCNYRate }
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                problem = ChatErrorDescription.describe(error)
            }
        } else {
            do {
                results = try await searchWithModel(query)
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                problem = ChatErrorDescription.describe(error)
            }
        }
        if let problem {
            log(.warning, "搜索失败：\(problem)")
            return Step(outcome: ToolLoop.Outcome(["error": .string(problem)]))
        }
        let hosts = results.compactMap { URL(string: $0.url)?.host()?.replacingOccurrences(of: "www.", with: "") }
        var shown: [String] = []
        for host in hosts where !shown.contains(host) && shown.count < 3 { shown.append(host) }
        log(.page, "\(results.count) 个网页" + (shown.isEmpty ? "" : "：" + shown.joined(separator: "、")))
        return Step(outcome: ToolLoop.Outcome(["results": .array(results.map(\.json))]))
    }

    /// 不是 DeepSeek 官方地址时：同一个模型另发一次只开服务商自带搜索的请求。
    private func searchWithModel(_ query: String) async throws -> [CompilationTools.SearchResult] {
        let request = CompilationTools.searchRequest(model: model.modelID, query: query, dialect: model.webSearchDialect)
        var text = ""
        var sources: [WebSource] = []
        var usage = ToolLoop.Usage()
        var recorder = WebSearchRecorder()
        for try await event in service.streamChat(request) {
            tick()
            switch event {
            case let .text(delta): text += delta
            case let .usage(input, output):
                if let input { usage.input = input }
                if let output { usage.output = output }
            case let .cachedInput(cached): usage.cachedInput = cached
            case let .searchResults(found): sources += found
            case let .citations(citations): sources += citations.flatMap(\.sources)
            default: break
            }
            _ = recorder.handle(event, content: text)
        }
        // 子请求里服务商自带搜索的次数和费用照常记到汇编上。
        usage.searches = max(recorder.record.effectiveCount, 1)
        record(usage)
        return CompilationTools.parseSearchReply(text, fallback: sources)
    }

    // MARK: - 读网页

    private func load(_ url: URL) async throws -> QuestionFetch.Page {
        do {
            return .html(try await PageFetcher.html(url))
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            if Task.isCancelled { throw CancellationError() }
            var status = CompilationTools.FetchStatus.failed
            if case let .http(code)? = error as? PageFetcher.FetchError { status = .forHTTP(code) }
            if let deepSeek, let data = try? await post(deepSeek, "fetch", ["url": .string(url.absoluteString)], timeout: 60),
               let value = try? JSONDecoder().decode(JSONValue.self, from: data),
               let markdown = value["content"]?.stringValue, !markdown.isEmpty {
                compilation.costCNY += Self.deepSeekToolPriceUSD * AppSettingsKey.usdToCNYRate
                return .fetched(title: value["title"]?.stringValue ?? "", markdown: markdown)
            }
            return .failed(status, ChatErrorDescription.describe(error))
        }
    }

    /// 模型给的网址：http 换成 https；已知取不到正文的网站（要登录、要下载文档）直接拒绝。
    private func pageURL(_ input: JSONValue) -> Swift.Result<URL, CompilationTools.ArgumentError> {
        switch CompilationTools.requiredString(input, "url") {
        case let .failure(error): return .failure(error)
        case let .success(raw):
            guard raw.hasPrefix("http") else { return .failure(.init("url 要以 https:// 开头")) }
            guard let url = CompilationPlanner.orderedCandidates([raw]).first else {
                return .failure(.init("这个网站 App 取不到正文（要登录、付费或下载文档），换一个网址"))
            }
            return .success(url)
        }
    }

    private static func host(_ url: URL) -> String {
        (url.host() ?? url.absoluteString).replacingOccurrences(of: "www.", with: "")
    }

    private func readPage(_ input: JSONValue) async throws -> Step {
        let url: URL
        switch pageURL(input) {
        case let .success(value): url = value
        case let .failure(error): return failure(error)
        }
        let host = Self.host(url)
        let page: PageText.Page
        var viaFetch = false
        switch try await load(url) {
        case let .html(html):
            page = await Task.detached { PageText.extract(html: html) }.value
        case let .fetched(title, markdown):
            page = PageText.Page(title: title, text: PageText.fromMarkdown(markdown))
            viaFetch = true
        case let .failed(status, reason):
            log(.warning, "读网页 \(host) · \(status.label)")
            return Step(outcome: ToolLoop.Outcome(["status": .string(status.rawValue), "error": .string(reason ?? status.label)]))
        }
        let limit = CompilationTools.pageTextLimit
        log(.page, "读网页 \(host) · \(page.text.count) 字" + (viaFetch ? "（Fetch API）" : ""))
        var result: [String: JSONValue] = [
            "title": .string(page.title),
            "text": .string(String(page.text.prefix(limit))),
        ]
        if page.text.count > limit { result["truncated"] = true }
        if viaFetch { result["note"] = "网站拒绝 App 直接下载，这是 Fetch API 读到的文字，没有图" }
        return Step(outcome: ToolLoop.Outcome(.object(result)), host: page.text.isEmpty ? nil : host)
    }

    // MARK: - 获取

    private var paperQuestions: [ExamQuestion] {
        guard case let .paper(paper) = phase else { return [] }
        return (compilation.questions ?? []).filter { $0.paperTitle == paper.title }
    }

    private func fetchQuestion(_ input: JSONValue) async throws -> Step {
        guard case let .paper(paper) = phase else { return failure(.init("这一步不能取题")) }
        let number: String
        let anchor: String
        let url: URL
        switch CompilationTools.requiredString(input, "number") {
        case let .success(value): number = CompilationTools.normalizeNumber(value)
        case let .failure(error): return failure(error)
        }
        switch CompilationTools.requiredString(input, "anchor") {
        case let .success(value): anchor = value
        case let .failure(error): return failure(error)
        }
        switch pageURL(input) {
        case let .success(value): url = value
        case let .failure(error): return failure(error)
        }
        let lastAnchor = input["last_anchor"]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let host = Self.host(url)
        let label = "获取第 \(number) 题 · \(CompilationPlanner.siteName(for: url))"

        let attempt: QuestionFetch.Attempt
        switch try await QuestionFetch.attempt(url: url, anchor: anchor, lastAnchor: lastAnchor, number: number, load: { try await self.load($0) }) {
        case let .success(value): attempt = value
        case let .failure(status, reason):
            log(.warning, "\(label) · \(status.label)")
            var result: [String: JSONValue] = ["status": .string(status.rawValue)]
            if let reason { result["error"] = .string(reason) }
            // 网页下载到了但没找到题，也算读到了这个网站。
            return Step(outcome: ToolLoop.Outcome(.object(result)), host: status == .notFound || status == .tooLong ? host : nil)
        }

        let status = attempt.status
        let existing = paperQuestions.first { CompilationTools.sameNumber($0.number, number) }
        var saved = false
        var note: String?
        if let existing, !CompilationTools.isBetter(status, than: existing.status) {
            note = "这道题已经有同样完整或更完整的结果，没有替换"
        } else {
            let question = existing ?? newQuestion(paper: paper, number: number)
            question.anchor = anchor
            question.lastAnchor = lastAnchor
            question.candidateURLs = [url.absoluteString] + question.candidateURLs.filter { $0 != url.absoluteString }
            QuestionFetch.apply(attempt, to: question, context: context)
            saved = true
            // 模型把共用一段材料的几道小题分开取了：内容一样的只留一份，题号合并。
            if let same = paperQuestions.first(where: { $0.id != question.id && $0.content == question.content && !$0.content.isEmpty }) {
                same.number = CompilationCenter.mergedNumber(same.number, question.number)
                note = "和第 \(question.number) 题是同一组题，已合并成第 \(same.number) 题"
                context.delete(question)
            }
            try? context.save()
        }
        let figures = attempt.result.imageURLs.isEmpty ? "" : " · 图 \(attempt.images.count)/\(attempt.result.imageURLs.count)"
        let site = attempt.result.answer.isEmpty ? "" : " · 带网站解析"
        log(status == .complete ? .success : .warning, "\(label) · \(status == .complete ? "完整" : "有图未能获取")\(figures)\(site)" + (saved ? "" : "（没有替换）"))

        var result: [String: JSONValue] = [
            "status": .string(status == .complete ? CompilationTools.FetchStatus.complete.rawValue : CompilationTools.FetchStatus.imagesMissing.rawValue),
            "saved": .bool(saved),
            "text": .string(CompilationTools.textForModel(attempt.result.content)),
            "has_site_answer": .bool(!attempt.result.answer.isEmpty),
        ]
        if !attempt.result.imageURLs.isEmpty {
            result["figures"] = .string("\(attempt.images.count)/\(attempt.result.imageURLs.count)")
        }
        if attempt.viaFetch { result["note"] = "网站拒绝 App 直接下载，用 Fetch API 取到了文字，没有图；能找到别的网站时换一个再取" }
        if let note { result["note"] = .string(note) }
        return Step(outcome: ToolLoop.Outcome(.object(result)), host: host, newQuestion: saved)
    }

    private func newQuestion(paper: PaperPlan, number: String) -> ExamQuestion {
        let question = ExamQuestion(
            paperTitle: paper.title, year: paper.year, number: number,
            index: (compilation.questions?.map(\.index).max() ?? -1) + 1
        )
        question.paperShortTitle = paper.shortTitle
        context.insert(question)
        question.compilation = compilation
        return question
    }

    private func removeQuestion(_ input: JSONValue) -> Step {
        let number: String
        switch CompilationTools.requiredString(input, "number") {
        case let .success(value): number = value
        case let .failure(error): return failure(error)
        }
        guard let question = paperQuestions.first(where: { CompilationTools.sameNumber($0.number, number) }) else {
            return Step(outcome: ToolLoop.Outcome(["error": .string("这份试卷里没有取到第 \(number) 题")]))
        }
        let reason = input["reason"]?.stringValue ?? ""
        log(.warning, "去掉第 \(question.number) 题" + (reason.isEmpty ? "" : "：\(reason)"))
        context.delete(question)
        try? context.save()
        return Step(outcome: ToolLoop.Outcome(["ok": true]), newQuestion: true)
    }

    private func finishPaper(_ input: JSONValue) -> Step {
        let note = input["note"]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        finishNote = note
        log(.success, "这份试卷完成" + (note.isEmpty ? "" : "：\(note)"))
        return Step(outcome: ToolLoop.Outcome(["ok": true], stop: true))
    }

    // MARK: - 列试卷和整理

    private func submitPapers(_ input: JSONValue) -> Step {
        switch CompilationTools.parsePapers(input, fallbackTitle: compilation.request) {
        case let .failure(error):
            return failure(error)
        case let .success(list):
            submitted = list
            log(.success, "列出了 \(list.papers.count) 份试卷")
            return Step(outcome: ToolLoop.Outcome(["ok": true], stop: true))
        }
    }

    /// 整理时给模型看的题目列表，编号是 Q1、Q2…
    func arrangeItems() -> [CompilationTools.ArrangeItem] {
        arrangeIDs = [:]
        arrangeOrder = []
        return compilation.sortedQuestions.enumerated().map { index, question in
            let id = "Q\(index + 1)"
            arrangeIDs[id] = question
            arrangeOrder.append(id)
            let preview = CompilationTools.textForModel(question.content, limit: 40).replacingOccurrences(of: "\n", with: " ")
            return CompilationTools.ArrangeItem(id: id, label: question.label, preview: preview.isEmpty ? "（未能获取原文）" : preview)
        }
    }

    private func arrange(_ input: JSONValue) -> Step {
        switch CompilationTools.parseArrangement(input, ids: arrangeOrder, fallbackTitle: compilation.title) {
        case let .failure(error):
            return failure(error)
        case let .success(arrangement):
            for (index, id) in arrangement.order.enumerated() {
                guard let question = arrangeIDs[id] else { continue }
                question.index = index
                question.groupName = arrangement.groups[id] ?? ""
            }
            compilation.title = arrangement.title
            compilation.pdfData = nil
            try? context.save()
            let groups = Set(arrangement.groups.values).count
            log(.success, "整理：\(arrangement.title)" + (groups > 0 ? " · 分成 \(groups) 组" : ""))
            return Step(outcome: ToolLoop.Outcome(["ok": true, "questions": .number(Double(arrangement.order.count))]))
        }
    }

    private func makePDF(_ input: JSONValue) -> Step {
        compilation.includeAnswers = input["include_answers"]?.boolValue ?? true
        pdfRequested = true
        try? context.save()
        return Step(outcome: ToolLoop.Outcome(["ok": true], stop: true))
    }

    // MARK: - DeepSeek Search API / Fetch API

    private func post(_ api: (base: URL, key: String), _ path: String, _ body: JSONValue, timeout: TimeInterval) async throws -> Data {
        var request = URLRequest(url: api.base.appending(path: path), timeoutInterval: timeout)
        request.httpMethod = "POST"
        request.setValue("Bearer \(api.key)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(body)
        let (data, response) = try await URLSession.shared.data(for: request)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw ChatServiceError.http(status: http.statusCode, message: APIErrorMessage.extract(from: data))
        }
        return data
    }
}

/// 从一个网页取一道原题：下载、按那几个字定位、下载图片。工具和"重新获取"共用。
@MainActor
enum QuestionFetch {
    struct Attempt {
        let url: URL
        let result: QuestionExtractor.Result
        /// 序号 → 图片数据和类型。
        let images: [Int: (Data, String)]
        /// 用 Fetch API 读到的文字，没有图。
        let viaFetch: Bool

        var status: ExamQuestionStatus {
            images.count == result.imageURLs.count && !result.probablyMissingImages && !viaFetch ? .complete : .imagesMissing
        }
    }

    /// 下载一个网页的结果。
    enum Page {
        case html(String)
        /// 直接下载被拒绝，用 Fetch API 读到的 Markdown（没有图）。
        case fetched(title: String, markdown: String)
        case failed(CompilationTools.FetchStatus, String?)
    }

    enum Outcome {
        case success(Attempt)
        case failure(CompilationTools.FetchStatus, String?)
    }

    /// load 负责下载网页（工具里还会在被拒绝时改用 Fetch API）。
    static func attempt(
        url: URL, anchor: String, lastAnchor: String, number: String,
        load: (URL) async throws -> Page
    ) async throws -> Outcome {
        let html: String
        let viaFetch: Bool
        switch try await load(url) {
        case let .html(text): html = text; viaFetch = false
        case let .fetched(_, markdown): html = PageText.html(fromMarkdown: markdown); viaFetch = true
        case let .failed(status, reason): return .failure(status, reason)
        }
        let group = QuestionExtractor.isGroupNumber(number)
        let extracted = await Task.detached {
            QuestionExtractor.extract(html: html, baseURL: url, anchor: anchor, lastAnchor: lastAnchor, group: group)
        }.value
        let result: QuestionExtractor.Result
        switch extracted {
        case let .success(value): result = value
        case .failure(.notFound): return .failure(.notFound, nil)
        case .failure(.tooLong): return .failure(.tooLong, nil)
        }
        var images: [Int: (Data, String)] = [:]
        if !viaFetch {
            for (index, address) in result.imageURLs.enumerated() {
                try Task.checkCancellation()
                guard let imageURL = URL(string: address), let image = try? await PageFetcher.image(imageURL, referer: url) else { continue }
                images[index] = image
            }
        }
        return .success(Attempt(url: url, result: result, images: images, viaFetch: viaFetch))
    }

    /// 把取到的原文、图和网站解析存进这道题，替换原来的。
    static func apply(_ attempt: Attempt, to question: ExamQuestion, context: ModelContext) {
        for image in question.images ?? [] { context.delete(image) }
        question.images = []
        var assets: [Int: UUID] = [:]
        for (index, image) in attempt.images {
            let stored = StoredImage(data: image.0, contentType: image.1)
            context.insert(stored)
            stored.question = question
            assets[index] = stored.id
        }
        question.content = CompilationPlanner.assemble(attempt.result.content, assets: assets)
        question.sourceURL = attempt.url.absoluteString
        if !attempt.result.answer.isEmpty, question.answerKind != .ai || question.answer.isEmpty {
            question.answer = CompilationPlanner.assemble(attempt.result.answer, assets: assets)
            question.answerKind = .site
            question.answerSite = CompilationPlanner.siteName(for: attempt.url)
        }
        question.status = attempt.status
        question.compilation?.pdfData = nil
    }
}
