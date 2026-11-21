import PDFKit
import StudyKit
import SwiftData
import SwiftUI

/// 汇编列表，按科目分节。
struct CompilationsView: View {
    @Environment(\.modelContext) private var context
    @Environment(CompilationCenter.self) private var center
    @Query(sort: \Compilation.updatedAt, order: .reverse) private var compilations: [Compilation]
    @State private var showNew = false
    @State private var opened: Compilation?

    private var groups: [(subject: Subject?, items: [Compilation])] {
        let order: [Subject?] = [nil] + Subject.allCases
        return order.compactMap { subject in
            let items = compilations.filter { $0.subject == subject }
            return items.isEmpty ? nil : (subject, items)
        }
    }

    var body: some View {
        List {
            ForEach(groups, id: \.subject) { group in
                Section(group.subject?.rawValue ?? "整理中") {
                    ForEach(group.items) { compilation in
                        NavigationLink {
                            CompilationDetailView(compilation: compilation)
                        } label: {
                            CompilationRow(compilation: compilation)
                        }
                        .swipeActions {
                            Button("删除", systemImage: "trash", role: .destructive) {
                                center.stop(compilation)
                                context.delete(compilation)
                                try? context.save()
                            }
                        }
                    }
                }
            }
        }
        .overlay {
            if compilations.isEmpty {
                OrbEmptyState(
                    title: "还没有汇编",
                    message: "用一句话说要什么题，例如\"近 3 年高考有机大题\"。模型联网找到试卷和原题，App 取下原文和原图，排版成 PDF。"
                ) {
                    Button("新建汇编") { showNew = true }
                        .buttonStyle(.borderedProminent)
                }
            }
        }
        .navigationTitle("汇编")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button("新建汇编", systemImage: "plus") { showNew = true }
            }
        }
        .sheet(isPresented: $showNew) {
            NewCompilationSheet { opened = $0 }
        }
        .navigationDestination(item: $opened) { compilation in
            CompilationDetailView(compilation: compilation)
        }
    }
}

private struct CompilationRow: View {
    let compilation: Compilation
    @Environment(CompilationCenter.self) private var center

    var body: some View {
        HStack(spacing: Theme.Spacing.m) {
            VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
                Text(compilation.title).lineLimit(1)
                Text(statusText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            if center.isRunning(compilation) {
                Spacer()
                ActivityOrb(activity: compilation.status == .listing ? .searching : .background)
            }
        }
        .padding(.vertical, 2)
    }

    private var statusText: String {
        if let progress = center.progress[compilation.id] { return progress }
        let count = compilation.questions?.count ?? 0
        switch compilation.status {
        case .listing: return "正在查找试卷…"
        case .choosing: return "已列出 \(compilation.papers.count) 份试卷，等你确认"
        case .collecting, .paused: return "已暂停 · 已收 \(count) 题"
        case .done: return "\(count) 题" + (compilation.pdfData == nil ? "" : " · 已生成 PDF")
        case .failed: return compilation.errorText ?? "失败"
        }
    }
}

/// 新建汇编：一句话要求，选一个支持联网搜索的模型。
struct NewCompilationSheet: View {
    let onCreated: (Compilation) -> Void

    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @Environment(CompilationCenter.self) private var center
    @State private var request = ""
    @State private var modelID: UUID?
    @State private var models: [ChatModel] = []

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("例如：近 3 年高考有机大题", text: $request, axis: .vertical)
                        .lineLimit(2...5)
                } header: {
                    Text("要什么题")
                } footer: {
                    Text("考试类型不限：高考、中考、各地模拟考都可以。说得越具体，找得越准，例如年份范围、地区、题型。")
                }
                Section {
                    if models.isEmpty {
                        Text("还没有支持联网搜索的模型。请在设置里为模型打开\"支持联网搜索\"（DeepSeek、Claude、Gemini 等）。")
                            .foregroundStyle(.secondary)
                    } else {
                        Picker("模型", selection: $modelID) {
                            ForEach(models) { model in
                                Text(model.name).tag(Optional(model.id))
                            }
                        }
                    }
                } footer: {
                    Text("先列出试卷给你确认，确认后才逐份查题。DeepSeek 会打开深度搜索，自己打开网页核对原文。")
                }
            }
            .navigationTitle("新建汇编")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("查找试卷", action: create)
                        .disabled(trimmed.isEmpty || selectedModel == nil)
                }
            }
            .onAppear {
                models = CompilationCenter.searchModels(in: context)
                if modelID == nil { modelID = models.first?.id }
            }
        }
    }

    private var trimmed: String {
        request.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var selectedModel: ChatModel? {
        models.first { $0.id == modelID }
    }

    private func create() {
        guard let model = selectedModel else { return }
        let compilation = center.create(request: trimmed, model: model, context: context)
        dismiss()
        onCreated(compilation)
    }
}

/// 一份汇编：按进行到的步骤显示试卷确认、进度、题目列表和 PDF。
struct CompilationDetailView: View {
    @Bindable var compilation: Compilation

    @Environment(\.modelContext) private var context
    @Environment(CompilationCenter.self) private var center
    @State private var pdfItem: PDFItem?
    @State private var isMakingPDF = false
    @State private var errorMessage: String?
    @State private var editMode: EditMode = .inactive

    private var isRunning: Bool { center.isRunning(compilation) }

    var body: some View {
        List {
            header
            switch compilation.status {
            case .listing:
                Section {
                    HStack(spacing: Theme.Spacing.s) {
                        ActivityOrb(activity: .searching)
                        Text(center.progress[compilation.id] ?? "正在联网查找试卷…")
                    }
                }
            case .failed:
                Section {
                    Label(compilation.errorText ?? "查找试卷失败。", systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.red)
                    Button("重试", systemImage: "arrow.clockwise") {
                        center.listPapers(compilation, context: context)
                    }
                }
            case .choosing:
                paperChooser
            case .collecting, .paused, .done:
                progressSection
                questionList
            }
        }
        .environment(\.editMode, $editMode)
        .navigationTitle(compilation.title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { toolbar }
        .sheet(item: $pdfItem) { item in
            PDFPreviewSheet(item: item)
        }
        .alert("提示", isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })) {
            Button("好", role: .cancel) {}
        } message: {
            Text(errorMessage ?? "")
        }
    }

    // MARK: - 部分

    private var header: some View {
        Section {
            VStack(alignment: .leading, spacing: 4) {
                Text(compilation.request)
                Text(summary)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var summary: String {
        var parts = [compilation.modelName]
        if compilation.searches > 0 { parts.append("搜索 \(compilation.searches) 次") }
        if compilation.costCNY > 0 { parts.append(UsageFormatting.cost(compilation.costCNY)) }
        return parts.filter { !$0.isEmpty }.joined(separator: " · ")
    }

    @ViewBuilder
    private var paperChooser: some View {
        let papers = compilation.papers
        let selected = papers.filter(\.selected).count
        Section {
            ForEach(papers) { paper in
                Toggle(isOn: Binding(
                    get: { paper.selected },
                    set: { value in
                        var all = compilation.papers
                        if let index = all.firstIndex(where: { $0.id == paper.id }) { all[index].selected = value }
                        compilation.papers = all
                    }
                )) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(paper.title)
                        if !paper.year.isEmpty {
                            Text(paper.year).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
            }
        } header: {
            Text("找到 \(papers.count) 份试卷")
        } footer: {
            VStack(alignment: .leading, spacing: 6) {
                Text(costText(selected: selected))
                if selected > 30 {
                    Text("试卷比较多，生成会很久、费用也高，可以先取消勾选一部分，或者缩小范围重新查找。")
                        .foregroundStyle(.orange)
                }
            }
        }
        Section {
            Button("开始收集 \(selected) 份试卷", systemImage: "play.fill") {
                center.startCollecting(compilation, context: context)
            }
            .disabled(selected == 0)
            Button("重新查找试卷", systemImage: "arrow.clockwise") {
                center.listPapers(compilation, context: context)
            }
        }
    }

    private func costText(selected: Int) -> String {
        let model = compilation.modelID.flatMap { id in
            try? context.fetch(FetchDescriptor<ChatModel>(predicate: #Predicate { $0.id == id })).first
        }
        let estimate = CompilationPlanner.estimateCostCNY(papers: selected, price: model?.price(), usdToCNY: AppSettingsKey.usdToCNYRate)
        let minutes = max(1, selected / 2)
        var text = "已选 \(selected) 份，大约需要 \(minutes) 分钟"
        if let estimate { text += "，预估费用" + UsageFormatting.cost(estimate) }
        return text + "。生成期间可以切到别的 App，进度会随时保存。"
    }

    @ViewBuilder
    private var progressSection: some View {
        let papers = compilation.papers.filter(\.selected)
        let done = papers.filter { $0.state == .done }.count
        Section {
            if isRunning {
                VStack(alignment: .leading, spacing: Theme.Spacing.s) {
                    ProgressView(value: Double(done), total: Double(max(papers.count, 1)))
                    HStack(spacing: Theme.Spacing.s) {
                        ActivityOrb(activity: .background)
                        Text(center.progress[compilation.id] ?? "正在收集…")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                }
                Button("停止", systemImage: "stop.fill", role: .destructive) { center.stop(compilation) }
            } else if compilation.status != .done {
                if let error = compilation.errorText {
                    Text(error).font(.callout).foregroundStyle(.orange)
                }
                Button("继续收集（已完成 \(done)/\(papers.count) 份）", systemImage: "play.fill") {
                    center.startCollecting(compilation, context: context)
                }
            }
            DisclosureGroup("试卷（\(done)/\(papers.count)）") {
                ForEach(papers) { paper in
                    HStack {
                        Image(systemName: icon(for: paper.state))
                            .foregroundStyle(paper.state == .failed ? .red : .secondary)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(paper.title).font(.callout)
                            if !paper.note.isEmpty || paper.state == .done {
                                Text(paper.note.isEmpty ? "\(paper.found) 题" : paper.note)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }
        }
    }

    private func icon(for state: PaperPlan.State) -> String {
        switch state {
        case .pending: "circle"
        case .done: "checkmark.circle.fill"
        case .failed: "exclamationmark.circle.fill"
        }
    }

    @ViewBuilder
    private var questionList: some View {
        let questions = compilation.sortedQuestions
        Section {
            ForEach(questions) { question in
                NavigationLink {
                    ExamQuestionDetailView(question: question)
                } label: {
                    ExamQuestionRow(question: question)
                }
            }
            .onDelete { offsets in
                offsets.map { questions[$0] }.forEach(context.delete)
                compilation.pdfData = nil
                try? context.save()
            }
            .onMove { from, to in
                var items = questions
                items.move(fromOffsets: from, toOffset: to)
                for (index, item) in items.enumerated() { item.index = index }
                compilation.pdfData = nil
                try? context.save()
            }
        } header: {
            Text("\(questions.count) 题")
        } footer: {
            if questions.contains(where: { $0.status != .complete }) {
                Text("标\"未能获取\"的题可以点进去重新获取。")
            }
        }
        if compilation.status == .done || !questions.isEmpty {
            Section {
                Toggle("PDF 附答案和解析", isOn: Binding(
                    get: { compilation.includeAnswers },
                    set: { compilation.includeAnswers = $0; compilation.pdfData = nil; try? context.save() }
                ))
                Button(compilation.pdfData == nil ? "生成 PDF" : "重新生成 PDF", systemImage: "doc.richtext", action: makePDF)
                    .disabled(isMakingPDF || questions.isEmpty || isRunning)
                if isMakingPDF {
                    HStack { ProgressView(); Text("正在排版…").foregroundStyle(.secondary) }
                }
                if let data = compilation.pdfData {
                    Button("查看和分享 PDF", systemImage: "square.and.arrow.up") {
                        pdfItem = PDFItem(data: data, title: compilation.title)
                    }
                }
            } footer: {
                if let date = compilation.pdfGeneratedAt, compilation.pdfData != nil {
                    Text("生成于 \(date.formatted(date: .abbreviated, time: .shortened))")
                }
            }
        }
    }

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        if !compilation.sortedQuestions.isEmpty && !isRunning {
            ToolbarItem(placement: .primaryAction) {
                EditButton()
            }
        }
    }

    private func makePDF() {
        isMakingPDF = true
        Task {
            defer { isMakingPDF = false }
            do {
                let data = try await CompilationPDF.make(compilation)
                compilation.pdfData = data
                compilation.pdfGeneratedAt = .now
                try? context.save()
                pdfItem = PDFItem(data: data, title: compilation.title)
            } catch {
                errorMessage = "生成 PDF 失败：\(error.localizedDescription)"
            }
        }
    }
}

private struct ExamQuestionRow: View {
    let question: ExamQuestion

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Text(question.label).font(.callout.bold())
                switch question.status {
                case .complete: EmptyView()
                case .imagesMissing: Tag(text: "有图未能获取", color: .orange)
                case .notFetched: Tag(text: "未能获取原文", color: .red)
                }
            }
            if !question.content.isEmpty {
                Text(preview)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
        }
        .padding(.vertical, 2)
    }

    private var preview: String {
        CompilationCenter.textForModel(question.content)
            .replacingOccurrences(of: #"\$\\rm\s*"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: "$", with: "")
            .replacingOccurrences(of: "\n", with: " ")
    }
}

struct Tag: View {
    let text: String
    let color: Color

    var body: some View {
        Text(text)
            .font(.caption2)
            .padding(.horizontal, 6)
            .padding(.vertical, 1)
            .foregroundStyle(color)
            .overlay(Capsule().stroke(color.opacity(0.6), lineWidth: 0.5))
    }
}

/// 一道原题：查看、改原文、重新获取、写 AI 解析、加入错题本。
struct ExamQuestionDetailView: View {
    @Bindable var question: ExamQuestion

    @Environment(\.modelContext) private var context
    @Environment(CompilationCenter.self) private var center
    @State private var isEditing = false
    @State private var showsPreview = false
    @State private var draftContent = ""
    @State private var draftAnswer = ""
    @State private var previewID = UUID()
    @State private var addedToMistakes = false

    private var isBusy: Bool { center.isBusy(question) }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                HStack(spacing: 6) {
                    Text(question.label).font(.headline)
                    switch question.status {
                    case .complete: EmptyView()
                    case .imagesMissing: Tag(text: "有图未能获取", color: .orange)
                    case .notFetched: Tag(text: "未能获取原文", color: .red)
                    }
                }
                if isEditing {
                    editor
                } else {
                    content
                }
            }
            .padding()
            .frame(maxWidth: 820)
            .frame(maxWidth: .infinity)
        }
        .navigationTitle(question.label)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if isEditing {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { isEditing = false }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") {
                        question.content = draftContent
                        question.answer = draftAnswer
                        if question.answer.isEmpty { question.answerKind = .none }
                        if !question.content.isEmpty, question.status == .notFetched { question.status = .complete }
                        question.compilation?.pdfData = nil
                        try? context.save()
                        isEditing = false
                    }
                }
            } else {
                ToolbarItem(placement: .primaryAction) {
                    Menu {
                        Button("编辑原文", systemImage: "pencil") {
                            draftContent = question.content
                            draftAnswer = question.answer
                            showsPreview = false
                            isEditing = true
                        }
                        Button("重新获取", systemImage: "arrow.clockwise") {
                            center.refetch(question, context: context)
                        }
                        .disabled(isBusy)
                        Button(question.answer.isEmpty ? "写 AI 解析" : "改用 AI 解析", systemImage: "sparkles") {
                            center.writeAIExplanation(question, context: context)
                        }
                        .disabled(isBusy || question.content.isEmpty)
                        Button(addedToMistakes ? "已加入错题本" : "加入错题本", systemImage: "exclamationmark.bubble") {
                            StudyCenter.addExamQuestion(question, context: context)
                            addedToMistakes = true
                        }
                        .disabled(addedToMistakes || question.content.isEmpty)
                    } label: {
                        Image(systemName: "ellipsis.circle")
                    }
                }
            }
        }
        .onChange(of: showsPreview) { previewID = UUID() }
    }

    @ViewBuilder
    private var content: some View {
        if isBusy {
            HStack(spacing: Theme.Spacing.s) {
                ActivityOrb(activity: center.isRefetching(question) ? .retrying : .working)
                Text(center.isRefetching(question) ? "正在重新获取…" : "正在写 AI 解析…").foregroundStyle(.secondary)
            }
        }
        if question.content.isEmpty {
            Text("没能从网页上取到这道题的原文。可以点右上角\"重新获取\"，或者打开下面的网页查看。")
                .foregroundStyle(.secondary)
        } else {
            RenderedContentView(id: question.id, content: question.content)
        }
        if !question.answer.isEmpty {
            Divider()
            HStack {
                Text("答案与解析").font(.headline)
                Tag(text: CompilationPDF.answerLabel(question), color: question.answerKind == .ai ? .purple : .blue)
            }
            RenderedContentView(id: answerID, content: question.answer)
        }
        let links = ([question.sourceURL] + question.candidateURLs).filter { !$0.isEmpty }
        let unique = links.reduce(into: [String]()) { result, link in if !result.contains(link) { result.append(link) } }
        if !unique.isEmpty {
            SourceListView(sources: unique.map { WebSource(url: $0, title: "") }, numbered: false)
        }
    }

    /// 答案用一个固定的 id，避免和题目的 WebView 高度缓存冲突。
    private var answerID: UUID {
        UUID(uuidString: String(question.id.uuidString.dropLast(1)) + "A") ?? question.id
    }

    @ViewBuilder
    private var editor: some View {
        Picker("", selection: $showsPreview) {
            Text("原文").tag(false)
            Text("预览").tag(true)
        }
        .pickerStyle(.segmented)
        if showsPreview {
            RenderedContentView(id: previewID, content: draftContent)
            if !draftAnswer.isEmpty {
                Divider()
                RenderedContentView(id: answerID, content: draftAnswer)
            }
        } else {
            Text("题目").font(.caption).foregroundStyle(.secondary)
            TextEditor(text: $draftContent)
                .font(.system(.callout, design: .monospaced))
                .frame(minHeight: 280)
                .scrollContentBackground(.hidden)
                .padding(Theme.Spacing.s)
                .cardBackground()
            Text("答案与解析").font(.caption).foregroundStyle(.secondary)
            TextEditor(text: $draftAnswer)
                .font(.system(.callout, design: .monospaced))
                .frame(minHeight: 200)
                .scrollContentBackground(.hidden)
                .padding(Theme.Spacing.s)
                .cardBackground()
            Text("图片写成 ![](sa-asset:…)，可以删除或移动，不要改里面的编号。")
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
    }
}

/// 要预览的 PDF，用来驱动 `.sheet(item:)`。
struct PDFItem: Identifiable {
    let id = UUID()
    let data: Data
    let title: String
}

struct PDFPreviewSheet: View {
    let item: PDFItem

    @Environment(\.dismiss) private var dismiss
    @State private var shareItem: ShareItem?

    var body: some View {
        NavigationStack {
            PDFKitView(data: item.data)
                .ignoresSafeArea(edges: .bottom)
                .navigationTitle(item.title)
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("完成") { dismiss() }
                    }
                    ToolbarItem(placement: .primaryAction) {
                        Button("分享", systemImage: "square.and.arrow.up") {
                            if let url = try? ExportFile.write(item.data, name: item.title, fallback: "汇编", extension: "pdf") {
                                shareItem = ShareItem(items: [url])
                            }
                        }
                    }
                }
                .sheet(item: $shareItem) { item in
                    ShareSheet(items: item.items)
                        .presentationDetents([.medium, .large])
                }
        }
    }
}

struct PDFKitView: UIViewRepresentable {
    let data: Data

    func makeUIView(context: Context) -> PDFView {
        let view = PDFView()
        view.autoScales = true
        view.displayMode = .singlePageContinuous
        view.document = PDFDocument(data: data)
        return view
    }

    func updateUIView(_ view: PDFView, context: Context) {}
}
