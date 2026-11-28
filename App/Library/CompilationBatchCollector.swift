import Foundation
import StudyKit
import SwiftData

/// 汇编的单次模型请求：搜索只用于发现来源，本地选题请求不联网。
@MainActor
final class CompilationBatchSession {
    let compilation: Compilation
    let model: ChatModel
    let service: any ChatService
    let log: CompilationCenter.Logger

    init(compilation: Compilation, model: ChatModel, service: any ChatService, log: @escaping CompilationCenter.Logger) {
        self.compilation = compilation
        self.model = model
        self.service = service
        self.log = log
    }

    func reply(to request: ChatRequest) async throws -> String {
        var text = ""
        var usage = ToolLoop.Usage()
        var recorder = WebSearchRecorder()
        // 失败或取消前已经返回的用量也要记账。
        defer {
            usage.searches = recorder.record.effectiveCount
            compilation.searches += usage.searches
            if let price = model.price(), usage.input != nil || usage.output != nil {
                compilation.costCNY += price.costCNY(
                    inputTokens: usage.input ?? 0, cachedInputTokens: usage.cachedInput,
                    outputTokens: usage.output ?? 0, webSearches: usage.searches,
                    usdToCNY: AppSettingsKey.usdToCNYRate, at: usage.started
                )
            }
        }
        for try await event in service.streamChat(request) {
            try Task.checkCancellation()
            BackgroundKeeper.shared.tick()
            switch event {
            case let .text(delta): text += delta
            case let .usage(input, output):
                if let input { usage.input = input }
                if let output { usage.output = output }
            case let .cachedInput(count): usage.cachedInput = count
            case let .searching(query):
                log(.search, query.map { "集中检索：\($0)" } ?? "集中检索试卷来源")
            default: break
            }
            _ = recorder.handle(event, content: text)
        }
        try Task.checkCancellation()
        return text
    }
}

/// 先复用本地题目和整卷来源，再集中发现缺失来源；所有原文、原图均从实际下载的页面提取。
@MainActor
final class CompilationBatchCollector {
    private let session: CompilationBatchSession
    private let context: ModelContext
    private let store: CompilationSourceStore
    private let imageLoader: (URL, URL) async throws -> (Data, String)
    private var visited = Set<String>()
    private var visitedScopes = Set<String>()
    private var completedURLs = Set<String>()
    private var refreshed = false
    private var nextSourceID = 0
    private var discovered = false
    private var paper: PaperPlan
    private let onlyNumber: String?
    private var reusable: [String: (CompilationReuse.Candidate, ExamQuestion)] = [:]

    init(
        session: CompilationBatchSession, context: ModelContext, paper: PaperPlan,
        store: CompilationSourceStore, onlyNumber: String? = nil,
        imageLoader: @escaping (URL, URL) async throws -> (Data, String) = { try await PageFetcher.image($0, referer: $1) }
    ) {
        self.session = session
        self.context = context
        self.paper = paper
        self.store = store
        self.onlyNumber = onlyNumber
        self.imageLoader = imageLoader
    }

    private var compilation: Compilation { session.compilation }
    private var task: String {
        if let onlyNumber { return "\(compilation.request)\n本次重新获取第 \(onlyNumber) 题，必须从原页重新选择这道题，其他题不要选；只需核实这道题完整，不要求收齐整卷。" }
        return compilation.request
    }
    private var questions: [ExamQuestion] {
        (compilation.questions ?? []).filter { $0.paperTitle == paper.title && $0.year == paper.year }
    }

    func collect() async throws -> PaperPlan {
        try Task.checkCancellation()
        let candidates = try CompilationReuse.candidates(for: paper, in: compilation, context: context)
        if onlyNumber == nil, let ready = candidates.first(where: \.canReuseAll) {
            let copied = CompilationReuse.copy(ready, into: compilation, paper: paper, context: context)
            try context.save()
            paper.sourceURLs = CompilationBatch.validSourceURLs(paper.sourceURLs + ready.sourceURLs)
            session.log(.success, "复用本地已完成试卷，共 \(copied.count) 题")
            return finish(complete: true)
        }
        for candidate in candidates {
            paper.sourceURLs = CompilationBatch.validSourceURLs(paper.sourceURLs + candidate.sourceURLs)
            if onlyNumber != nil { continue }
            for question in candidate.questions {
                if let onlyNumber, !CompilationTools.sameNumber(question.number, onlyNumber) { continue }
                if reusable.values.contains(where: { CompilationTools.sameNumber($0.1.number, question.number) }) { continue }
                reusable["R\(reusable.count + 1)"] = (candidate, question)
            }
        }
        try persistSources()
        if !reusable.isEmpty {
            session.log(.step, "从本地已取得的题目中筛选")
            let text = try await session.reply(to: CompilationBatch.selectionRequest(
                model: session.model.modelID, request: task, paper: paper,
                documents: "本次只筛选已有题目 R 编号，来源的卷名、年份和学科已匹配。questions 和 links 留空，不据此认定整卷已完整收集。",
                existing: existingDescription()
            ))
            let selection = try CompilationBatch.parseSelection(text).get()
            if selection.matchesPaper {
                for id in selection.reuse {
                    guard let (_, question) = reusable[id] else { continue }
                    _ = CompilationReuse.copyQuestions([question], into: compilation, paper: paper, context: context)
                }
                try context.save()
            }
            reusable.removeAll()
        }

        // 相同来源通常已在本机，不必为新的选题要求再次搜索。
        if try await processSources(paper.sourceURLs) { return finish(complete: true) }
        try Task.checkCancellation()
        if !discovered {
            discovered = true
            session.log(.step, "集中查找\(paper.shortTitle.isEmpty ? paper.title : paper.shortTitle)的整卷或题目目录")
            var searchTask = task
            let complete = questions.filter { $0.status == .complete && onlyNumber == nil }.map(\.number)
            if !complete.isEmpty { searchTask += "\n已完整取得第 \(complete.joined(separator: "、")) 题，只寻找其余缺失内容的来源。" }
            if !visited.isEmpty { searchTask += "\n以下页面已尝试，仍未完整取到，请寻找其他出处：\n" + visited.sorted().joined(separator: "\n") }
            let text = try await session.reply(to: CompilationBatch.discoveryRequest(
                model: session.model.modelID, request: searchTask, paper: paper, dialect: session.model.webSearchDialect
            ))
            let urls = try CompilationBatch.parseSources(text).get()
            // 新的出处先保存，暂停或退出后仍能从这些网址继续。
            paper.sourceURLs = CompilationBatch.validSourceURLs(urls + paper.sourceURLs)
            try persistSources()
            if try await processSources(urls) { return finish(complete: true) }
        }
        return finish(complete: false)
    }

    private func processSources(_ urls: [String]) async throws -> Bool {
        for url in CompilationPlanner.orderedCandidates(urls) {
            let complete = try await process(url, parent: nil, depth: 0)
            if onlyNumber != nil ? refreshed : complete { return true }
        }
        return false
    }

    /// 目录只跟随模型从真实 href 中选出的链接，不接受模型生成的网址。
    private func process(_ url: URL, parent: String?, depth: Int) async throws -> Bool {
        try Task.checkCancellation()
        var canonical = URLComponents(url: url, resolvingAgainstBaseURL: false)
        canonical?.fragment = nil
        let address = canonical?.url?.absoluteString ?? url.absoluteString
        guard depth <= 2 else { return false }
        // 目录子页的完成只证明该页取全，不能供根来源复用为整卷完成。
        let scope = (parent == nil ? "root:" : "linked:") + address
        if completedURLs.contains(scope) { return true }
        guard visitedScopes.insert(scope).inserted else { return false }
        visited.insert(address)
        let html: String
        do {
            html = try await store.html(for: url)
        } catch {
            try Task.checkCancellation()
            if error is CancellationError { throw error }
            session.log(.warning, "读取 \(url.host() ?? address) 失败：\(ChatErrorDescription.describe(error))")
            return false
        }
        try Task.checkCancellation()
        let document = await Task.detached { PaperDocument(html: html, url: url) }.value
        guard !document.blocks.isEmpty else {
            store.invalidate(for: url)
            return false
        }
        nextSourceID += 1
        let sourceID = "S\(nextSourceID)"
        session.log(.page, "本地选题：\(document.title.isEmpty ? url.host() ?? address : document.title)")

        var complete = true
        var matches = false
        var links: [PaperDocument.Link] = []
        var pending: [(CompilationBatch.QuestionRange, [PaperDocument.Block])] = []
        let batches = Self.pageBatches(document)
        for (index, batch) in batches.enumerated() {
            try Task.checkCancellation()
            let blocks = batch.blocks
            let visible = Set(blocks.map(\.id))
            let text = Self.describe(document, sourceID: sourceID, batch: batch, part: index + 1, parts: batches.count, parent: parent)
            let response = try await session.reply(to: CompilationBatch.selectionRequest(
                model: session.model.modelID, request: task, paper: paper,
                documents: text, existing: existingDescription()
            ))
            let selection = try CompilationBatch.parseSelection(response).get()
            guard selection.matchesPaper else {
                store.invalidate(for: url)
                session.log(.warning, selection.note.isEmpty ? "网页与这份试卷不符，跳过" : selection.note)
                return false
            }
            matches = true
            complete = complete && selection.complete
            for id in selection.reuse {
                guard let (_, question) = reusable[id] else { complete = false; continue }
                _ = CompilationReuse.copyQuestions([question], into: compilation, paper: paper, context: context)
            }
            for range in selection.questions {
                guard range.sourceID == sourceID, visible.contains(range.startID), visible.contains(range.endID),
                      onlyNumber.map({ CompilationTools.sameNumber(range.number, $0) }) ?? true,
                      range.group == QuestionExtractor.isGroupNumber(range.number) else {
                    complete = false
                    continue
                }
                pending.append((range, blocks))
            }
            for selected in selection.links {
                guard selected.sourceID == sourceID, let link = batch.links.first(where: { $0.id == selected.linkID }) else {
                    complete = false
                    continue
                }
                if !links.contains(where: { $0.url == link.url }) { links.append(link) }
            }
        }
        // 全部批次都核对过卷名后再保存，避免后续批次发现错卷时留下错误原题。
        for (range, blocks) in pending {
            if onlyNumber == nil, questions.contains(where: { CompilationTools.sameNumber($0.number, range.number) && $0.status == .complete }) { continue }
            switch document.extract(startID: range.startID, endID: range.endID, group: range.group) {
            case let .success(result):
                if !(try await save(result, number: range.number, document: document, blocks: blocks, range: range)) { complete = false }
            case .failure:
                complete = false
                session.log(.warning, "第 \(range.number) 题的正文范围无效，保留为待补取")
            }
        }
        // 一份目录可以直接下载多道题，整个过程不调用搜索 API。
        for link in links {
            guard let raw = CompilationBatch.validSourceURLs([link.url]).first, let child = URL(string: raw) else {
                complete = false
                continue
            }
            let childComplete = try await process(child, parent: "\(document.title)\n目录中的题目：\(link.title)", depth: depth + 1)
            complete = childComplete && complete
        }
        try context.save()
        if matches && complete { completedURLs.insert(scope) }
        return matches && complete
    }

    private func save(
        _ result: QuestionExtractor.Result, number: String, document: PaperDocument,
        blocks: [PaperDocument.Block], range: CompilationBatch.QuestionRange
    ) async throws -> Bool {
        var images: [Int: (Data, String)] = [:]
        for (index, raw) in result.imageURLs.enumerated() {
            try Task.checkCancellation()
            guard let url = URL(string: raw) else { continue }
            do { images[index] = try await imageLoader(url, document.url) }
            catch {
                try Task.checkCancellation()
                if error is CancellationError { throw error }
            }
        }
        try Task.checkCancellation()
        let attempt = QuestionFetch.Attempt(url: document.url, result: result, images: images, viaFetch: false)
        let existing = questions.first { CompilationTools.sameNumber($0.number, number) }
        if CompilationTools.isBetter(attempt.status, than: existing?.status) || (onlyNumber != nil && attempt.status == .complete) {
            let question = existing ?? ExamQuestion(
                paperTitle: paper.title, year: paper.year, number: CompilationTools.normalizeNumber(number),
                index: (compilation.questions?.map(\.index).max() ?? -1) + 1
            )
            if existing == nil { context.insert(question); question.compilation = compilation }
            question.paperShortTitle = paper.shortTitle
            question.anchor = String((blocks.first { $0.id == range.startID }?.text ?? "").prefix(30))
            question.lastAnchor = String((blocks.first { $0.id == range.endID }?.text ?? "").prefix(30))
            question.candidateURLs = [document.url.absoluteString]
            QuestionFetch.apply(attempt, to: question, context: context)
            try context.save()
            if onlyNumber != nil, attempt.status == .complete { refreshed = true }
        }
        session.log(attempt.status == .complete ? .success : .warning,
                    "本地提取第 \(number) 题 · \(attempt.status == .complete ? "完整" : "有图未能获取")")
        return attempt.status == .complete
    }

    private func existingDescription() -> String {
        let current = questions.filter { $0.status == .complete && onlyNumber == nil }.map { "已取得第 \($0.number) 题，不必重复提取。" }
        let candidates = reusable.keys.sorted().compactMap { id -> String? in
            guard let (_, question) = reusable[id] else { return nil }
            return "\(id) 第 \(question.number) 题：\(CompilationTools.textForModel(question.content, limit: 2500))"
        }
        return (current + candidates).joined(separator: "\n")
    }

    private func persistSources() throws {
        var papers = compilation.papers
        if let index = papers.firstIndex(where: { $0.id == paper.id }) {
            papers[index].sourceURLs = paper.sourceURLs
            compilation.papers = papers
            try context.save()
        }
    }

    private func finish(complete: Bool) -> PaperPlan {
        paper.found = questions.count
        paper.collectionComplete = complete && questions.allSatisfy { $0.status == .complete }
        paper.state = paper.collectionComplete ? .done : .failed
        paper.note = paper.collectionComplete
            ? (paper.found == 0 ? "已核对来源，没有符合要求的题" : "")
            : "已保留 \(paper.found) 题；来源或原图不完整，可继续补取"
        return paper
    }

    struct PageBatch {
        let blocks: [PaperDocument.Block]
        let links: [PaperDocument.Link]
        let oversized: Bool
    }

    /// 同一页的链接只送一次。正文批有余量时顺带放链接，其余链接独立分批，目录尾部不会丢失。
    static func pageBatches(_ document: PaperDocument, limit: Int = 24_000) -> [PageBatch] {
        let limit = max(1, limit)
        var result: [PageBatch] = []
        var linkIndex = 0
        for blocks in batches(document.blocks, limit: limit) {
            var size = blocks.reduce(0) { $0 + $1.text.count + $1.id.count + 2 }
            var links: [PaperDocument.Link] = []
            while linkIndex < document.links.count {
                let link = document.links[linkIndex]
                let added = link.id.count + link.title.count + link.url.count + 6
                guard size + added <= limit else { break }
                links.append(link)
                size += added
                linkIndex += 1
            }
            result.append(PageBatch(blocks: blocks, links: links, oversized: size > limit))
        }
        while linkIndex < document.links.count {
            var links: [PaperDocument.Link] = []
            var size = 0
            while linkIndex < document.links.count {
                let link = document.links[linkIndex]
                let added = link.id.count + link.title.count + link.url.count + 6
                if !links.isEmpty, size + added > limit { break }
                links.append(link)
                size += added
                linkIndex += 1
            }
            result.append(PageBatch(blocks: [], links: links, oversized: size > limit))
        }
        return result
    }

    /// 先按题号分出完整题，阅读材料与它覆盖的小题保持同批；没有题号的正文才按段重叠分批。
    static func batches(_ blocks: [PaperDocument.Block], limit: Int = 24_000) -> [[PaperDocument.Block]] {
        guard !blocks.isEmpty else { return [] }
        let limit = max(1, limit)
        var boundaries = [0]
        var readingEnd: Int?
        var mainNumber: Int?
        for (index, block) in blocks.enumerated() {
            if let end = readingGroupEnd(block.text) {
                if index > boundaries.last! { boundaries.append(index) }
                readingEnd = end
                mainNumber = end
            } else if let number = questionNumber(block.text) {
                if let end = readingEnd, number <= end { continue }
                readingEnd = nil
                // 主编号后的回落编号是题内步骤，不能在步骤之间拆开完整题。
                if let mainNumber, number <= mainNumber { continue }
                mainNumber = number
                if index > boundaries.last! { boundaries.append(index) }
            }
        }
        // 有明确题号时按整题打包，不在题干和最后几问之间切断。
        if boundaries.count > 1 {
            boundaries.append(blocks.count)
            var result: [[PaperDocument.Block]] = []
            var current: [PaperDocument.Block] = []
            var size = 0
            for index in 0..<(boundaries.count - 1) {
                let unit = Array(blocks[boundaries[index]..<boundaries[index + 1]])
                let added = unit.reduce(0) { $0 + $1.text.count }
                if !current.isEmpty, size + added > limit {
                    result.append(current)
                    current = []
                    size = 0
                }
                current += unit
                size += added
            }
            if !current.isEmpty { result.append(current) }
            return result
        }
        // 单题详情页即便超过软上限，也保留完整原题；调用描述会明确提示长题。
        if blocks.contains(where: { questionNumber($0.text) != nil || readingGroupEnd($0.text) != nil }) {
            return [blocks]
        }
        var result: [[PaperDocument.Block]] = []
        var start = 0
        while start < blocks.count {
            var end = start
            var size = 0
            while end < blocks.count, end == start || size + blocks[end].text.count <= limit {
                size += blocks[end].text.count
                end += 1
            }
            result.append(Array(blocks[start..<end]))
            guard end < blocks.count else { break }
            start = max(start + 1, end - min(8, (end - start) / 2))
        }
        return result
    }

    private static func questionNumber(_ text: String) -> Int? {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let range = text.range(of: #"^\d{1,3}\s*(?:[.．](?!\d)|、)"#, options: .regularExpression) else { return nil }
        return Int(text[range].prefix(while: \.isNumber))
    }

    private static func readingGroupEnd(_ text: String) -> Int? {
        guard ["阅读", "材料", "短文"].contains(where: text.contains),
              let range = text.range(of: #"\d{1,3}\s*[～~\-—–至、,，]\s*\d{1,3}\s*(?:小)?题"#, options: .regularExpression)
        else { return nil }
        return text[range].split(whereSeparator: { !$0.isNumber }).compactMap { Int($0) }.max()
    }

    static func describe(
        _ document: PaperDocument, sourceID: String, batch: PageBatch, part: Int, parts: Int, parent: String?
    ) -> String {
        var text = "来源 \(sourceID)\n网页标题：\(document.title)\n地址：\(document.url.absoluteString)"
        if let parent { text += "\n来自已经核对的试卷目录：\(parent)" }
        if parts > 1 {
            text += "\n资料第 \(part)/\(parts) 批：先核实原页是整卷或完整目录，complete 才能表示本批已检查并选全。没有目录上下文的单题页不能据此认定整卷完整。其余正文和链接会在其他批次送齐。"
            // 身份核对只带简短页首，不给正文块 ID，避免把摘要中的题当作可取范围。
            let identity = document.blocks.prefix(3).map { String($0.text.prefix(400)) }.joined(separator: "\n")
            text += "\n页首身份线索（仅用于核对，可能截短，不能选为题目）：\n" + identity
        } else if parent == nil {
            text += "\n这是该页的全部资料。必须确认是完整整卷或完整目录才可 complete=true；单题详情页不能证明整卷已选全。本次若明确只重新获取一道题，则以该题完整为准。"
        } else {
            text += "\n这是目录指向页面的全部资料，complete 表示该页相关题目已选全。"
        }
        if batch.blocks.isEmpty {
            text += "\n本批只有目录链接，没有可选择的正文块，questions 必须为空；逐一核对并选择所有相关题目的链接。"
        } else {
            text += "\n可选择的完整正文块：\n" + batch.blocks.map { "\($0.id)：\($0.text)" }.joined(separator: "\n")
            text += "\n题目若跨出本批边界，不能只取一半，须 complete=false 并在 note 说明。"
        }
        if batch.oversized { text += "\n本批含超过通常批次长度的完整题组、段落或链接，已完整保留，不要截掉结尾。" }
        text += "\n本批可选择的真实链接（只会提供一次）：\n" + batch.links.map { "\($0.id)：\($0.title) · \($0.url)" }.joined(separator: "\n")
        return text
    }
}
