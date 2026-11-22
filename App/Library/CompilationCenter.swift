import Foundation
import Observation
import StudyKit
import SwiftData
import UIKit

enum CompilationError: LocalizedError {
    case noModel
    case modelCannotSearch
    case unreadableReply

    var errorDescription: String? {
        switch self {
        case .noModel: "这个汇编用的模型已经删除了，请新建汇编。"
        case .modelCannotSearch: "这个模型没有打开\"支持联网搜索\"，汇编需要联网搜索。"
        case .unreadableReply: "模型的回答看不懂，请重试。"
        }
    }
}

/// 生成汇编：请模型列试卷、逐份试卷找题、从网页取原题（见 docs/adr/0013）。放在 App 层级，切换页面时不中断。
@MainActor
@Observable
final class CompilationCenter {
    private var tasks: [UUID: Task<Void, Never>] = [:]
    /// 正在做什么，例如"正在查第 3/12 份：北京卷"。
    private(set) var progress: [UUID: String] = [:]
    /// 正在重新获取或写解析的题。
    private(set) var busyQuestions: Set<UUID> = []
    /// 正在重新获取的题（busyQuestions 的一部分），界面上用"重试"的小球。
    private(set) var refetchingQuestions: Set<UUID> = []
    /// 因为切到别的 App 被系统打断的汇编。回到 App 时自动继续。
    private(set) var interrupted: Set<UUID> = []

    /// 收集过程里的一行，显示在汇编页面上（只在内存里，App 重启后清空）。
    struct ActivityLine: Identifiable {
        enum Kind { case step, search, page, success, warning }
        let id = UUID()
        let time = Date.now
        let kind: Kind
        let text: String
    }
    typealias Logger = (ActivityLine.Kind, String) -> Void

    /// 每个汇编最近的收集过程，最多 80 行。
    private(set) var activity: [UUID: [ActivityLine]] = [:]
    /// 这一轮开始的时间和已经搜索的次数，用来显示"已搜索 N 次 · 用时"。
    private(set) var runStats: [UUID: (started: Date, searches: Int)] = [:]

    private func logger(for id: UUID) -> Logger {
        { [weak self] kind, text in self?.log(id, kind, text) }
    }

    private func log(_ id: UUID, _ kind: ActivityLine.Kind, _ text: String) {
        var lines = activity[id] ?? []
        // 同一句话连着出现（模型反复搜同一个词）只记一次。
        if let last = lines.last, last.kind == kind, last.text == text { return }
        lines.append(ActivityLine(kind: kind, text: text))
        if lines.count > 80 { lines.removeFirst(lines.count - 80) }
        activity[id] = lines
        if kind == .search, var stats = runStats[id] {
            stats.searches += 1
            runStats[id] = stats
        }
    }

    private func beginRun(_ id: UUID) {
        runStats[id] = (.now, 0)
    }

    static let interruptedText = "切到别的 App 后，系统暂停了格物，网络也断开了。已经保存进度，回到格物后会自动继续。打开设置里的强力保活就不会被暂停。"

    func isRunning(_ compilation: Compilation) -> Bool {
        tasks[compilation.id] != nil
    }

    /// 支持联网搜索的模型，默认模型排在最前面。
    static func searchModels(in context: ModelContext) -> [ChatModel] {
        let all = (try? context.fetch(FetchDescriptor<ChatModel>(sortBy: [SortDescriptor(\.createdAt)]))) ?? []
        let usable = all.filter { $0.supportsWebSearch && $0.provider != nil }
        let defaultID = ModelLookup.defaultModel(in: context)?.id
        return usable.sorted { ($0.id == defaultID ? 0 : 1) < ($1.id == defaultID ? 0 : 1) }
    }

    // MARK: - 第一步：列试卷

    func create(request: String, model: ChatModel, context: ModelContext) -> Compilation {
        let compilation = Compilation(request: request)
        compilation.modelID = model.id
        compilation.modelName = model.name
        context.insert(compilation)
        try? context.save()
        listPapers(compilation, context: context)
        return compilation
    }

    func listPapers(_ compilation: Compilation, context: ModelContext) {
        guard tasks[compilation.id] == nil else { return }
        compilation.status = .listing
        compilation.errorText = nil
        try? context.save()
        progress[compilation.id] = "正在联网查找试卷…"
        let id = compilation.id
        interrupted.remove(id)
        // 查找试卷是一次很长的联网请求（深度搜索要几分钟），切到别的 App 时也要在后台继续。
        BackgroundKeeper.shared.begin(id: id, title: "汇编：\(compilation.request)", subtitle: "正在联网查找试卷") { [weak self] in
            self?.interrupt(id)
        }
        let started = Date.now
        tasks[id] = Task { [weak self] in
            defer {
                self?.tasks[id] = nil
                self?.progress[id] = nil
            }
            let log = self?.logger(for: id)
            self?.beginRun(id)
            log?(.step, "开始联网查找符合要求的试卷")
            do {
                let (model, service) = try Self.resolve(compilation, context: context)
                let raw = try await Self.run(
                    CompilationPlanner.listPapersRequest(
                        model: model.modelID, request: compilation.request, reasoningEffort: Self.effort(for: model),
                        webSearchDialect: model.webSearchDialect
                    ),
                    service: service, model: model, compilation: compilation, log: log
                )
                guard let list = CompilationPlanner.parsePaperList(raw, fallbackTitle: compilation.request) else {
                    throw CompilationError.unreadableReply
                }
                compilation.title = list.title
                compilation.subject = list.subject ?? .other
                compilation.papers = list.papers
                compilation.status = .choosing
                log?(.success, "列出了 \(list.papers.count) 份试卷")
            } catch {
                log?(.warning, "查找试卷没有完成：\(ChatErrorDescription.describe(error))")
                compilation.status = .failed
                if self?.interrupted.contains(id) == true || (!Task.isCancelled && Self.isBackgroundInterruption(error, since: started)) {
                    self?.interrupted.insert(id)
                    compilation.errorText = Self.interruptedText
                } else {
                    compilation.errorText = Task.isCancelled ? "已停止。" : ChatErrorDescription.describe(error)
                }
            }
            compilation.updatedAt = .now
            try? context.save()
            BackgroundKeeper.shared.end(id: id, success: compilation.status == .choosing)
        }
    }

    // MARK: - 第二步：逐份试卷查题

    func startCollecting(_ compilation: Compilation, context: ModelContext) {
        guard tasks[compilation.id] == nil else { return }
        var papers = compilation.papers
        // 继续时，上次失败的试卷再试一次。
        for index in papers.indices where papers[index].selected && papers[index].state == .failed {
            papers[index].state = .pending
            papers[index].note = ""
        }
        compilation.papers = papers
        compilation.status = .collecting
        compilation.errorText = nil
        try? context.save()

        let id = compilation.id
        interrupted.remove(id)
        BackgroundKeeper.shared.begin(id: id, title: "汇编：\(compilation.title)") { [weak self] in
            self?.interrupt(id)
        }
        tasks[id] = Task { [weak self] in
            await self?.collect(compilation, context: context)
            BackgroundKeeper.shared.end(id: id, success: compilation.status == .done)
            self?.tasks[id] = nil
            self?.progress[id] = nil
        }
    }

    func stop(_ compilation: Compilation) {
        // 用户自己停下的，回到 App 时不自动继续。
        interrupted.remove(compilation.id)
        tasks[compilation.id]?.cancel()
    }

    /// 系统要结束后台运行：停下保存进度，记下来，回到 App 时自动继续。
    private func interrupt(_ id: UUID) {
        guard tasks[id] != nil else { return }
        interrupted.insert(id)
        tasks[id]?.cancel()
    }

    /// 回到前台时，继续被切到后台打断的汇编。
    func resumeInterrupted(in context: ModelContext) {
        for id in interrupted where tasks[id] == nil {
            interrupted.remove(id)
            let descriptor = FetchDescriptor<Compilation>(predicate: #Predicate { $0.id == id })
            guard let compilation = try? context.fetch(descriptor).first else { continue }
            switch compilation.status {
            case .failed: listPapers(compilation, context: context)
            case .paused: startCollecting(compilation, context: context)
            default: break
            }
        }
    }

    /// 这次网络错误是不是因为请求进行中 App 被切到了后台：iOS 挂起 App 时会断开它的连接。
    static func isBackgroundInterruption(_ error: any Error, since start: Date) -> Bool {
        let codes: [URLError.Code] = [.networkConnectionLost, .notConnectedToInternet, .timedOut, .cannotConnectToHost]
        guard let code = (error as? URLError)?.code, codes.contains(code) else { return false }
        if UIApplication.shared.applicationState != .active { return true }
        return (BackgroundKeeper.shared.lastEnteredBackground ?? .distantPast) >= start
    }

    /// App 上次在生成过程中被关闭时，把汇编标成可以继续。
    func recoverInterrupted(in context: ModelContext) {
        let compilations = (try? context.fetch(FetchDescriptor<Compilation>())) ?? []
        for compilation in compilations where tasks[compilation.id] == nil {
            switch compilation.status {
            case .collecting: compilation.status = .paused
            case .listing:
                compilation.status = .failed
                compilation.errorText = "上次查找试卷时 App 被关闭了，请重试。"
            default: break
            }
        }
        try? context.save()
    }

    private func collect(_ compilation: Compilation, context: ModelContext) async {
        let resolved: (ChatModel, any ChatService)
        do {
            resolved = try Self.resolve(compilation, context: context)
        } catch {
            compilation.status = .paused
            compilation.errorText = ChatErrorDescription.describe(error)
            try? context.save()
            return
        }
        let (model, service) = resolved
        let selected = compilation.papers.filter(\.selected)
        var stopped = false
        let log = logger(for: compilation.id)
        beginRun(compilation.id)

        for paper in selected where paper.state == .pending {
            if Task.isCancelled { stopped = true; break }
            let done = compilation.papers.filter { $0.selected && $0.state != .pending }.count
            let name = paper.shortTitle.isEmpty ? paper.title : paper.shortTitle
            let found = compilation.questions?.count ?? 0
            progress[compilation.id] = "正在查第 \(done + 1)/\(selected.count) 份：\(name)"
            BackgroundKeeper.shared.update(
                id: compilation.id, completed: done, total: selected.count,
                subtitle: "第 \(done + 1)/\(selected.count) 份 · 已找到 \(found) 题"
            )

            var updated = paper
            let started = Date.now
            log(.step, "第 \(done + 1)/\(selected.count) 份：\(name)")
            do {
                let raw = try await Self.run(
                    CompilationPlanner.findQuestionsRequest(
                        model: model.modelID, request: compilation.request, paper: paper, reasoningEffort: Self.effort(for: model),
                        webSearchDialect: model.webSearchDialect
                    ),
                    service: service, model: model, compilation: compilation, log: log
                )
                guard let questions = CompilationPlanner.parseFoundQuestions(raw) else { throw CompilationError.unreadableReply }
                log(.success, questions.isEmpty ? "这份试卷里没有符合要求的题" : "找到 \(questions.count) 道符合要求的题，开始取原文")
                for item in questions {
                    if Task.isCancelled { throw CancellationError() }
                    progress[compilation.id] = "正在取第 \(item.number) 题：\(name)"
                    let question = ExamQuestion(
                        paperTitle: paper.title, year: paper.year, number: item.number,
                        index: (compilation.questions?.map(\.index).max() ?? -1) + 1
                    )
                    question.paperShortTitle = paper.shortTitle
                    question.anchor = item.anchor
                    question.lastAnchor = item.lastAnchor
                    question.candidateURLs = item.urls
                    context.insert(question)
                    question.compilation = compilation
                    await Self.fetch(question, context: context, log: log)
                    try? context.save()
                }
                updated.state = .done
                updated.found = questions.count
                updated.note = questions.isEmpty ? "这份试卷里没有符合要求的题" : ""
            } catch {
                if Task.isCancelled || error is CancellationError || (error as? URLError)?.code == .cancelled {
                    stopped = true
                } else if Self.isBackgroundInterruption(error, since: started) {
                    // 切到后台被断开：这份试卷不算失败，回到 App 后从它继续。
                    interrupted.insert(compilation.id)
                    stopped = true
                } else {
                    updated.state = .failed
                    updated.note = ChatErrorDescription.describe(error)
                    log(.warning, "这份没查成功：\(updated.note)")
                }
            }
            var papers = compilation.papers
            if let index = papers.firstIndex(where: { $0.id == paper.id }) { papers[index] = updated }
            compilation.papers = papers
            compilation.updatedAt = .now
            // 每查完一份保存一次进度，被系统中断后从这里继续。
            try? context.save()
            if stopped { break }
        }

        let remaining = compilation.papers.contains { $0.selected && $0.state != .done }
        compilation.status = stopped || remaining ? .paused : .done
        if interrupted.contains(compilation.id) {
            compilation.errorText = Self.interruptedText
        } else if !stopped, remaining {
            compilation.errorText = "有试卷没查成功，可以点\"继续\"再试一次。"
        }
        compilation.updatedAt = .now
        try? context.save()
    }

    // MARK: - 单道题

    /// 重新获取一道题：先按原来的网页再取一次；还不行就请模型重新找这道题。
    func refetch(_ question: ExamQuestion, context: ModelContext) {
        guard !busyQuestions.contains(question.id), let compilation = question.compilation else { return }
        busyQuestions.insert(question.id)
        refetchingQuestions.insert(question.id)
        BackgroundKeeper.shared.begin(id: question.id, title: "汇编：重新获取\(question.label)", subtitle: "正在重新获取")
        Task {
            defer {
                busyQuestions.remove(question.id)
                refetchingQuestions.remove(question.id)
                BackgroundKeeper.shared.end(id: question.id, success: question.status == .complete)
            }
            let log = logger(for: compilation.id)
            log(.step, "重新获取\(question.label)")
            await Self.fetch(question, context: context, log: log)
            if question.status != .complete, let resolved = try? Self.resolve(compilation, context: context) {
                let (model, service) = resolved
                let paper = PaperPlan(title: question.paperTitle, shortTitle: question.paperShortTitle, year: question.year)
                if let raw = try? await Self.run(
                    CompilationPlanner.findQuestionsRequest(
                        model: model.modelID, request: compilation.request, paper: paper,
                        onlyNumber: question.number.isEmpty ? nil : question.number, reasoningEffort: Self.effort(for: model),
                        webSearchDialect: model.webSearchDialect
                    ),
                    service: service, model: model, compilation: compilation, log: log
                ), let found = CompilationPlanner.parseFoundQuestions(raw)?.first {
                    let previous = question.candidateURLs
                    question.anchor = found.anchor
                    question.lastAnchor = found.lastAnchor
                    question.candidateURLs = found.urls + previous.filter { !found.urls.contains($0) }
                    await Self.fetch(question, context: context, log: log)
                }
            }
            try? context.save()
        }
    }

    func isBusy(_ question: ExamQuestion) -> Bool {
        busyQuestions.contains(question.id)
    }

    func isRefetching(_ question: ExamQuestion) -> Bool {
        refetchingQuestions.contains(question.id)
    }

    /// 没有答案时请模型写"AI 解析"。模型能看图时把题里的图一起发过去。
    func writeAIExplanation(_ question: ExamQuestion, context: ModelContext) {
        guard !busyQuestions.contains(question.id), let compilation = question.compilation else { return }
        busyQuestions.insert(question.id)
        BackgroundKeeper.shared.begin(id: question.id, title: "汇编：\(question.label)", subtitle: "正在写 AI 解析")
        Task {
            defer {
                busyQuestions.remove(question.id)
                BackgroundKeeper.shared.end(id: question.id, success: !question.answer.isEmpty)
            }
            do {
                let (model, service) = try Self.resolve(compilation, context: context, needsSearch: false)
                let images = model.supportsImages ? Self.jpegImages(of: question) : []
                let text = """
                请为下面这道考试题写一份解答：先写答案，再分步写解析。公式和化学式按格式规则书写。\
                \(images.isEmpty ? "题里的图看不到时，按文字尽量解答，并说明哪些地方需要看图核对。" : "题里的图按顺序附在后面。")

                \(question.label)
                \(Self.textForModel(question.content))
                """
                let request = ChatRequest(
                    model: model.modelID,
                    systemPrompt: SystemPrompt.compose(customInstructions: "", simpleMode: true),
                    messages: [ChatMessage(role: .user, text: text, images: images)],
                    reasoningEffort: model.reasoningEffort
                )
                question.answer = ""
                question.answerKind = .ai
                question.answerSite = ""
                var answer = ""
                for try await event in service.streamChat(request) {
                    BackgroundKeeper.shared.tick()
                    if case let .text(delta) = event {
                        answer += delta
                        question.answer = answer
                    }
                }
            } catch {
                if question.answer.isEmpty { question.answerKind = .none }
            }
            try? context.save()
        }
    }

    // MARK: - 内部

    private static func resolve(_ compilation: Compilation, context: ModelContext, needsSearch: Bool = true) throws -> (ChatModel, any ChatService) {
        guard let id = compilation.modelID,
              let model = try context.fetch(FetchDescriptor<ChatModel>(predicate: #Predicate { $0.id == id })).first
        else { throw CompilationError.noModel }
        if needsSearch && !model.supportsWebSearch { throw CompilationError.modelCannotSearch }
        return (model, try ModelLookup.service(for: model))
    }

    /// DeepSeek 打开思考时会自己多轮搜索、打开网页核对，适合找原题。
    private static func effort(for model: ChatModel) -> ReasoningEffort? {
        if let effort = model.reasoningEffort { return effort }
        return model.webSearchDialect == .deepSeek && model.provider?.kind == .openAICompatible ? .high : nil
    }

    /// 发一次请求，返回正文；用量和搜索次数记到汇编上。
    private static func run(
        _ request: ChatRequest, service: any ChatService, model: ChatModel, compilation: Compilation, log: Logger? = nil
    ) async throws -> String {
        var text = ""
        var input: Int?
        var cached = 0
        var output: Int?
        var recorder = WebSearchRecorder()
        let started = Date.now
        defer {
            let searches = recorder.record.effectiveCount
            compilation.searches += searches
            if let price = model.price(), input != nil || output != nil {
                compilation.costCNY += price.costCNY(
                    inputTokens: input ?? 0, cachedInputTokens: cached, outputTokens: output ?? 0, webSearches: searches,
                    usdToCNY: AppSettingsKey.usdToCNYRate, at: started
                )
            }
        }
        for try await event in service.streamChat(request) {
            BackgroundKeeper.shared.tick()
            switch event {
            case let .text(delta): text += delta
            case let .usage(newInput, newOutput):
                if let newInput { input = newInput }
                if let newOutput { output = newOutput }
            case let .cachedInput(value): cached = value
            case .reasoning: break
            case .searching, .searchResults, .citations, .searchCount:
                if case let .searching(query) = event, let query, !query.isEmpty {
                    log?(.search, "搜索：\(query)")
                }
                if case let .searchResults(sources) = event, !sources.isEmpty {
                    var hosts: [String] = []
                    for host in sources.compactMap(\.host) where !hosts.contains(host) && hosts.count < 3 { hosts.append(host) }
                    log?(.page, "看了 \(sources.count) 个网页" + (hosts.isEmpty ? "" : "：" + hosts.joined(separator: "、")))
                }
                _ = recorder.handle(event, content: text)
            }
        }
        return text
    }

    /// 按候选网页的顺序下载、定位、取原题和图片。原文和图都取到就停；只取到部分时继续找更好的。
    static func fetch(_ question: ExamQuestion, context: ModelContext, log: Logger? = nil) async {
        let anchor = question.anchor
        let lastAnchor = question.lastAnchor
        var best: (url: URL, result: QuestionExtractor.Result, images: [Int: (Data, String)])?
        for url in CompilationPlanner.orderedCandidates(question.candidateURLs) {
            if Task.isCancelled { return }
            let host = url.host() ?? url.absoluteString
            log?(.page, "\(question.label)：打开 \(host)")
            guard let html = try? await PageFetcher.html(url) else {
                log?(.warning, "\(host) 打不开，换下一个网页")
                continue
            }
            let extracted = await Task.detached {
                QuestionExtractor.extract(html: html, baseURL: url, anchor: anchor, lastAnchor: lastAnchor)
            }.value
            guard case let .success(result) = extracted else {
                log?(.warning, "\(host) 上没找到这道题，换下一个网页")
                continue
            }
            var images: [Int: (Data, String)] = [:]
            for (index, address) in result.imageURLs.enumerated() {
                guard let imageURL = URL(string: address), let image = try? await PageFetcher.image(imageURL, referer: url) else { continue }
                images[index] = image
            }
            let complete = images.count == result.imageURLs.count && !result.probablyMissingImages
            if complete || best == nil || images.count > (best?.images.count ?? 0) {
                best = (url, result, images)
            }
            if complete { break }
        }
        guard let best else {
            if question.content.isEmpty { question.status = .notFetched }
            log?(.warning, "\(question.label)：没能取到原文")
            return
        }
        for image in question.images ?? [] { context.delete(image) }
        question.images = []
        var assets: [Int: UUID] = [:]
        for (index, image) in best.images {
            let stored = StoredImage(data: image.0, contentType: image.1)
            context.insert(stored)
            stored.question = question
            assets[index] = stored.id
        }
        question.content = CompilationPlanner.assemble(best.result.content, assets: assets)
        question.sourceURL = best.url.absoluteString
        if !best.result.answer.isEmpty, question.answerKind != .ai || question.answer.isEmpty {
            question.answer = CompilationPlanner.assemble(best.result.answer, assets: assets)
            question.answerKind = .site
            question.answerSite = CompilationPlanner.siteName(for: best.url)
        }
        let allImages = best.images.count == best.result.imageURLs.count
        question.status = allImages && !best.result.probablyMissingImages ? .complete : .imagesMissing
        let figures = best.result.imageURLs.isEmpty ? "" : "，图 \(best.images.count)/\(best.result.imageURLs.count)"
        log?(question.status == .complete ? .success : .warning,
             "\(question.label)：取到原文\(figures)" + (question.answerKind == .site ? "，带网站解析" : ""))
    }

    /// 发给模型的题目文字：图片换成"[图]"。
    nonisolated static func textForModel(_ markdown: String) -> String {
        markdown.replacingOccurrences(of: #"!\[\]\(sa-asset:[^)]*\)"#, with: "[图]", options: .regularExpression)
    }

    /// 题里的图转成 JPEG（模型接口只收 JPEG）。SVG 转不了，跳过。
    static func jpegImages(of question: ExamQuestion) -> [Data] {
        let order = imageIDs(in: question.content)
        let byID = Dictionary((question.images ?? []).map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        return order.prefix(6).compactMap { id in
            guard let stored = byID[id], let data = stored.data, let image = UIImage(data: data) else { return nil }
            // 透明背景的 PNG 转 JPEG 会变黑，先铺白底。
            let renderer = UIGraphicsImageRenderer(size: image.size)
            let flattened = renderer.image { context in
                UIColor.white.setFill()
                context.fill(CGRect(origin: .zero, size: image.size))
                image.draw(at: .zero)
            }
            return flattened.jpegData(compressionQuality: 0.85)
        }
    }

    /// 正文里按顺序出现的图片 id。
    nonisolated static func imageIDs(in markdown: String) -> [UUID] {
        let pattern = try! NSRegularExpression(pattern: #"sa-asset:([0-9A-Fa-f-]{36})"#)
        let ns = markdown as NSString
        return pattern.matches(in: markdown, range: NSRange(location: 0, length: ns.length)).compactMap {
            UUID(uuidString: ns.substring(with: $0.range(at: 1)))
        }
    }
}
