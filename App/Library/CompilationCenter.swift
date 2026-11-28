import Foundation
import Observation
import StudyKit
import SwiftData
import UIKit

enum CompilationError: LocalizedError {
    case noModel
    case modelCannotSearch
    /// 列试卷时模型没有调用 submit_papers。
    case noPapers(String)

    var errorDescription: String? {
        switch self {
        case .noModel: "这个汇编用的模型已经删除了，请新建汇编。"
        case .modelCannotSearch: "这个模型没有打开\"支持联网搜索\"，汇编需要联网搜索。"
        case let .noPapers(reason): reason
        }
    }
}

/// 生成汇编：模型调用 App 的工具列试卷、逐份试卷取原题、整理并生成 PDF（见 docs/adr/0013、0014）。
/// 放在 App 层级，切换页面时不中断。
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

    /// 调用记录里的一行，显示在汇编页面上（只在内存里，App 重启后清空）。
    struct ActivityLine: Identifiable {
        enum Kind { case step, search, page, success, warning }
        let id = UUID()
        let time = Date.now
        let kind: Kind
        let text: String
    }
    typealias Logger = (ActivityLine.Kind, String) -> Void

    /// 每个汇编最近的调用记录，最多 80 行。
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
        let log = logger(for: id)
        beginRun(id)
        log(.step, "开始查找符合要求的试卷")
        tasks[id] = Task { [weak self] in
            defer {
                self?.tasks[id] = nil
                self?.progress[id] = nil
            }
            do {
                let (model, service) = try Self.resolve(compilation, context: context)
                let toolbox = CompilationToolbox(
                    compilation: compilation, context: context, model: model, service: service, phase: .listing, log: log
                )
                let result = try await Self.loop(
                    toolbox,
                    CompilationTools.listingRequest(model: model.modelID, request: compilation.request, reasoningEffort: Self.effort(for: model)),
                    maxCalls: CompilationTools.maxCallsForListing,
                    nudge: "核实完了就调用 submit_papers 交上试卷列表；还没核实完就继续用工具。"
                )
                try Task.checkCancellation()
                guard let list = toolbox.submitted else {
                    switch result.ending {
                    case let .answered(text):
                        let reason = text.trimmingCharacters(in: .whitespacesAndNewlines)
                        throw CompilationError.noPapers(reason.isEmpty ? "模型没有列出试卷，请把要求说具体一些再试。" : "模型没有列出试卷：\(reason.prefix(200))")
                    default:
                        throw CompilationError.noPapers("用满 \(CompilationTools.maxCallsForListing) 次调用也没有列出试卷，请把要求说具体一些再试。")
                    }
                }
                compilation.title = list.title
                compilation.subject = list.subject ?? .other
                compilation.papers = list.papers
                compilation.status = .choosing
            } catch {
                log(.warning, "查找试卷没有完成：\(ChatErrorDescription.describe(error))")
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
        log(id, .warning, "系统结束了后台运行，已保存进度")
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
            case .paused, .arranging: startCollecting(compilation, context: context)
            default: break
            }
        }
    }

    /// 这次网络错误是不是因为请求进行中 App 被切到了后台：iOS 挂起 App 时会断开它的连接。
    static func isBackgroundInterruption(_ error: any Error, since start: Date) -> Bool {
        let codes: [URLError.Code] = [.networkConnectionLost, .notConnectedToInternet, .timedOut, .cannotConnectToHost]
        guard let code = (error as? URLError)?.code, codes.contains(code) else { return false }
        // 强力保活开着时 App 在后台一直运行、没有被挂起，这是真的网络错误：
        // 按普通失败处理，这份试卷记为失败、接着查下一份，而不是整个汇编停下等回到 App。
        if BackgroundKeeper.shared.locationActive { return false }
        if UIApplication.shared.applicationState != .active { return true }
        return (BackgroundKeeper.shared.lastEnteredBackground ?? .distantPast) >= start
    }

    /// App 上次在生成过程中被关闭时，把汇编标成可以继续。
    func recoverInterrupted(in context: ModelContext) {
        let compilations = (try? context.fetch(FetchDescriptor<Compilation>())) ?? []
        for compilation in compilations where tasks[compilation.id] == nil {
            switch compilation.status {
            case .collecting, .arranging: compilation.status = .paused
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
        /// 换哪份试卷都会失败的错误（例如模型不支持工具调用）。
        var fatal: String?
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
            let toolbox = CompilationToolbox(
                compilation: compilation, context: context, model: model, service: service, phase: .paper(paper), log: log
            )
            do {
                // 中断后这份试卷从头再来：已经取到的题列在开头，模型不会重复取。
                let existing = Self.questions(of: paper, in: compilation).map {
                    CompilationTools.ExistingQuestion(number: $0.number, status: $0.status)
                }
                let result = try await Self.loop(
                    toolbox,
                    CompilationTools.paperRequest(
                        model: model.modelID, request: compilation.request, paper: paper, existing: existing,
                        reasoningEffort: Self.effort(for: model)
                    ),
                    maxCalls: CompilationTools.maxCallsPerPaper,
                    nudge: "这份试卷查完了就调用 finish_paper；还没取完就继续用工具。"
                )
                try Task.checkCancellation()
                let count = Self.questions(of: paper, in: compilation).count
                updated.state = .done
                updated.found = count
                if toolbox.stagnated {
                    updated.note = count == 0
                        ? "未能获取原文：连续 \(CompilationTools.maxCallsWithoutProgress) 次调用没有新进展"
                        : "连续 \(CompilationTools.maxCallsWithoutProgress) 次调用没有新进展，按已取到的 \(count) 题结束"
                } else if result.ending == .limitReached {
                    updated.note = "用满 \(CompilationTools.maxCallsPerPaper) 次调用，按已取到的 \(count) 题结束"
                    log(.warning, updated.note)
                } else if count == 0 {
                    updated.note = toolbox.finishNote.flatMap { $0.isEmpty ? nil : $0 } ?? "这份试卷里没有符合要求的题"
                } else {
                    updated.note = ""
                }
            } catch {
                if Task.isCancelled || error is CancellationError || (error as? URLError)?.code == .cancelled {
                    stopped = true
                } else if Self.isBackgroundInterruption(error, since: started) {
                    // 切到后台被断开：这份试卷不算失败，回到 App 后从它继续。
                    log(.warning, "切到后台后连接断开：\(ChatErrorDescription.describe(error))")
                    interrupted.insert(compilation.id)
                    stopped = true
                } else if (error as? ToolLoopError) == .toolsUnsupported {
                    // 换哪份试卷都一样，直接停下。
                    updated.state = .failed
                    updated.note = ChatErrorDescription.describe(error)
                    log(.warning, updated.note)
                    fatal = updated.note
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
        if !stopped, !remaining, !(compilation.questions ?? []).isEmpty, !Task.isCancelled {
            await arrange(compilation, model: model, service: service, context: context, log: log)
        }
        if Task.isCancelled { stopped = true }
        compilation.status = stopped || remaining ? .paused : .done
        if interrupted.contains(compilation.id) {
            compilation.errorText = Self.interruptedText
        } else if let fatal {
            compilation.errorText = fatal
        } else if !stopped, remaining {
            compilation.errorText = "有试卷没查成功，可以点\"继续\"再试一次。"
        }
        compilation.updatedAt = .now
        try? context.save()
    }

    // MARK: - 第三步：整理和生成 PDF

    /// 全部试卷查完后，请模型定标题、顺序和分组，再生成 PDF。失败时保留原来的顺序，不影响已经取到的题。
    private func arrange(
        _ compilation: Compilation, model: ChatModel, service: any ChatService, context: ModelContext, log: @escaping Logger
    ) async {
        compilation.status = .arranging
        try? context.save()
        progress[compilation.id] = "正在整理顺序和分组…"
        log(.step, "整理标题、顺序和分组")
        let toolbox = CompilationToolbox(
            compilation: compilation, context: context, model: model, service: service, phase: .arranging, log: log
        )
        let items = toolbox.arrangeItems()
        do {
            _ = try await Self.loop(
                toolbox,
                CompilationTools.arrangingRequest(
                    model: model.modelID, request: compilation.request, title: compilation.title, items: items,
                    reasoningEffort: Self.effort(for: model)
                ),
                maxCalls: CompilationTools.maxCallsForArranging,
                nudge: "请先调用 arrange，再调用 make_pdf。"
            )
        } catch {
            if Task.isCancelled { return }
            log(.warning, "整理没有完成，保留原来的顺序：\(ChatErrorDescription.describe(error))")
        }
        guard toolbox.pdfRequested || compilation.pdfData == nil else { return }
        await makePDFNowOrLater(compilation, context: context, log: log)
    }

    /// App 在前台时马上生成 PDF；在后台时渲染器可能不工作，记为"待生成"，回到前台再生成。
    private func makePDFNowOrLater(_ compilation: Compilation, context: ModelContext, log: Logger?) async {
        guard UIApplication.shared.applicationState == .active else {
            compilation.pdfPending = true
            try? context.save()
            log?(.step, "生成 PDF：App 在后台，回到格物后再生成")
            return
        }
        progress[compilation.id] = "正在生成 PDF…"
        do {
            let snapshot = CompilationPDF.document(for: compilation)
            let data = try await CompilationPDF.make(snapshot)
            try CompilationPDF.publish(data, for: compilation, snapshot: snapshot)
            log?(.success, "生成了 PDF")
        } catch {
            compilation.pdfPending = false
            log?(.warning, "生成 PDF 失败：\(error.localizedDescription)")
        }
        try? context.save()
    }

    /// 回到前台时，生成在后台时没能生成的 PDF。
    func makePendingPDFs(in context: ModelContext) {
        let compilations = (try? context.fetch(FetchDescriptor<Compilation>(predicate: #Predicate { $0.pdfPending }))) ?? []
        for compilation in compilations where tasks[compilation.id] == nil {
            let id = compilation.id
            tasks[id] = Task { [weak self] in
                await self?.makePDFNowOrLater(compilation, context: context, log: self?.logger(for: id))
                self?.tasks[id] = nil
                self?.progress[id] = nil
            }
        }
    }

    // MARK: - 单道题

    /// 重新获取一道题：先按原来的网页再取一次；还不行就请模型用工具重新找这道题。
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
            if question.status != .complete, !question.number.isEmpty, let resolved = try? Self.resolve(compilation, context: context) {
                let (model, service) = resolved
                let paper = PaperPlan(title: question.paperTitle, shortTitle: question.paperShortTitle, year: question.year)
                let toolbox = CompilationToolbox(
                    compilation: compilation, context: context, model: model, service: service, phase: .paper(paper), log: log
                )
                let existing = Self.questions(of: paper, in: compilation).map {
                    CompilationTools.ExistingQuestion(number: $0.number, status: $0.status)
                }
                do {
                    _ = try await Self.loop(
                        toolbox,
                        CompilationTools.paperRequest(
                            model: model.modelID, request: compilation.request, paper: paper, existing: existing,
                            onlyNumber: question.number, reasoningEffort: Self.effort(for: model)
                        ),
                        maxCalls: CompilationTools.maxCallsPerPaper / 2,
                        nudge: "取完了就调用 finish_paper。"
                    )
                } catch {
                    if !Task.isCancelled { log(.warning, "重新获取没有完成：\(ChatErrorDescription.describe(error))") }
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
                Self.setAIExplanation("", for: question)
                var answer = ""
                for try await event in service.streamChat(request) {
                    BackgroundKeeper.shared.tick()
                    if case let .text(delta) = event {
                        answer += delta
                        Self.setAIExplanation(answer, for: question)
                    }
                }
            } catch {
                if question.answer.isEmpty { question.answerKind = .none }
            }
            try? context.save()
        }
    }

    /// 答案变更后旧 PDF 不再可分享；正在生成解析时也不能继续排版上一次的待生成版本。
    static func setAIExplanation(_ text: String, for question: ExamQuestion) {
        question.answer = text
        question.answerKind = .ai
        question.answerSite = ""
        question.compilation?.pdfData = nil
        question.compilation?.pdfGeneratedAt = nil
        question.compilation?.pdfPending = false
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

    /// 跑一轮工具循环：工具由 toolbox 执行，用量记到汇编上，每个流式事件让后台进度往前走一点。
    private static func loop(
        _ toolbox: CompilationToolbox, _ request: ChatRequest, maxCalls: Int, nudge: String
    ) async throws -> ToolLoop.Result {
        try await ToolLoop(maxCalls: maxCalls, nudge: nudge).run(
            service: toolbox.service,
            request: request,
            onEvent: { _ in await toolbox.tick() },
            onUsage: { usage in await toolbox.record(usage) },
            execute: { call in try await toolbox.execute(call) }
        )
    }

    /// 这份试卷已经取到的题。
    private static func questions(of paper: PaperPlan, in compilation: Compilation) -> [ExamQuestion] {
        (compilation.questions ?? []).filter { $0.paperTitle == paper.title }
    }

    /// 按保存的候选网页再取一次：原文和图都取到就停；只取到部分时继续找更好的。
    static func fetch(_ question: ExamQuestion, context: ModelContext, log: Logger? = nil) async {
        var best: QuestionFetch.Attempt?
        for url in CompilationPlanner.orderedCandidates(question.candidateURLs) {
            if Task.isCancelled { return }
            let host = url.host() ?? url.absoluteString
            log?(.page, "\(question.label)：打开 \(host)")
            let outcome = try? await QuestionFetch.attempt(
                url: url, anchor: question.anchor, lastAnchor: question.lastAnchor, number: question.number
            ) { url in
                do { return .html(try await PageFetcher.html(url)) } catch { return .failed(.failed, nil) }
            }
            guard case let .success(attempt) = outcome else {
                log?(.warning, "\(host) 上没取到这道题，换下一个网页")
                continue
            }
            if attempt.status == .complete || best == nil || attempt.images.count > (best?.images.count ?? 0) {
                best = attempt
            }
            if attempt.status == .complete { break }
        }
        guard let best, CompilationTools.isBetter(best.status, than: question.content.isEmpty ? nil : question.status) else {
            if question.content.isEmpty { question.status = .notFetched }
            log?(.warning, "\(question.label)：按原来的网页没能取到更完整的原文")
            return
        }
        QuestionFetch.apply(best, to: question, context: context)
        let figures = best.result.imageURLs.isEmpty ? "" : "，图 \(best.images.count)/\(best.result.imageURLs.count)"
        log?(question.status == .complete ? .success : .warning,
             "\(question.label)：取到原文\(figures)" + (question.answerKind == .site ? "，带网站解析" : ""))
    }

    /// 合并题号，例如 18 和 20 → 18～20。
    nonisolated static func mergedNumber(_ a: String, _ b: String) -> String {
        let numbers = (a + " " + b).split(whereSeparator: { !$0.isNumber }).compactMap { Int($0) }
        guard let low = numbers.min(), let high = numbers.max(), low != high else { return a }
        return "\(low)～\(high)"
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
