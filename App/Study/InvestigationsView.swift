import StudyKit
import SwiftData
import SwiftUI

struct InvestigationsView: View {
    @Environment(\.modelContext) private var context
    @Environment(ToastCenter.self) private var toasts
    @Query(sort: \StudyInvestigation.updatedAt, order: .reverse) private var records: [StudyInvestigation]
    @State private var errorText: String?
    private var visible: [StudyInvestigation] { records.filter { !toasts.isHidden($0) } }

    var body: some View {
        List {
            Section("开始探索") {
                NavigationLink { ComparisonComposer() } label: {
                    Label("多解对照", systemImage: InvestigationKind.comparison.symbol)
                }
                NavigationLink { KnowledgeGapComposer() } label: {
                    Label("知识缺口定位", systemImage: InvestigationKind.gaps.symbol)
                }
                NavigationLink { ConditionExplorationComposer() } label: {
                    Label("条件探索", systemImage: InvestigationKind.conditions.symbol)
                }
                NavigationLink { ReadingComparisonComposer() } label: {
                    Label("资料对照阅读", systemImage: InvestigationKind.reading.symbol)
                }
            }
            Section("已保存的探索") {
                if visible.isEmpty { Text("分析材料、作答和结果会保存在这里。").foregroundStyle(.secondary) }
                ForEach(visible) { record in
                    NavigationLink {
                        if record.kind == .gaps { KnowledgeGapDetailView(record: record) }
                        else { InvestigationDetailView(record: record) }
                    } label: {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(record.title).lineLimit(2)
                            Text((record.kind?.title ?? "学习探索") + " · " + record.updatedAt.formatted(.relative(presentation: .named)))
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
                .onDelete { offsets in
                    let removed = offsets.map { visible[$0] }
                    toasts.delete(removed, scope: .investigations) {
                        for record in removed { context.delete(record) }
                        do { try context.save() } catch { errorText = ChatErrorDescription.describe(error) }
                    }
                }
            }
        }
        .navigationTitle("学习探索")
        .toastBar(.investigations)
        .studyError($errorText)
    }
}

struct ComparisonComposer: View {
    @Environment(\.modelContext) private var context
    @State private var material: StudyMaterial?
    @State private var question = ""
    @State private var ownSolution = ""
    @State private var model: ChatModel?
    @State private var choosing = false
    @State private var created: StudyInvestigation?
    @State private var errorText: String?

    var body: some View {
        Form {
            Section("同一道题") {
                Button("选择已有内容", systemImage: "books.vertical") { choosing = true }
                if let material {
                    Text(material.title).font(.headline)
                    Text(material.location).font(.caption).foregroundStyle(.secondary)
                    Button("改为手动输入") { self.material = nil; question = "" }
                } else {
                    TextEditor(text: $question).frame(minHeight: 140).accessibilityLabel("题目")
                }
            }
            Section("自己的解法（可选）") {
                TextEditor(text: $ownSolution).frame(minHeight: 140).accessibilityLabel("自己的解法")
                Text("原解法会完整保存，并与其他方法按共同目标逐步对照。").font(.caption).foregroundStyle(.secondary)
            }
            Section {
                ModelPickerMenu(selection: $model)
                Button("保存并对照", action: create).disabled(model == nil || (material == nil && question.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty))
                Text("材料将发送给所选模型，比较结果会标为 AI 分析。").font(.caption).foregroundStyle(.secondary)
            }
        }
        .navigationTitle("多解对照")
        .sheet(isPresented: $choosing) { StudyMaterialPicker { material = $0 } }
        .navigationDestination(item: $created) { record in InvestigationDetailView(record: record, autoStart: true) }
        .task { model = ModelLookup.defaultModel(in: context) }
        .studyError($errorText)
    }

    private func create() {
        guard let model else { return }
        let source = material ?? StudyMaterial(title: String(question.prefix(40)), content: question)
        do {
            let request = try SolutionComparison.request(model: model.modelID, question: source, ownSolution: ownSolution)
            _ = try InvestigationRunner.attachImages([source], to: request, model: model)
            let record = StudyInvestigation(kind: .comparison, title: source.title)
            try record.setMaterials([source]); record.inputText = ownSolution
            record.modelID = model.id
            context.insert(record)
            do { try context.save() } catch { context.delete(record); throw error }
            created = record
        } catch { errorText = ChatErrorDescription.describe(error) }
    }
}

struct InvestigationDetailView: View {
    let record: StudyInvestigation
    var autoStart = false
    @Environment(\.modelContext) private var context
    @State private var model: ChatModel?
    @State private var materials: [StudyMaterial] = []
    @State private var selection: StudyMaterial?
    @State private var runner = InvestigationRunner()
    @State private var task: Task<Void, Never>?
    @State private var errorText: String?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                Text(record.title).font(.title2.bold())
                ForEach(materials) { material in
                    Button { selection = material } label: { Label(material.title, systemImage: "doc.text.magnifyingglass") }
                }
                if !record.inputText.isEmpty && record.kind != .reading {
                    DisclosureGroup(record.kind == .conditions ? "原解法" : "自己的原解法") { StudyMarkdown(content: record.inputText) }
                }
                generationControls
                if !record.resultJSON.isEmpty {
                    Label("AI 分析 · \(record.modelName)", systemImage: "sparkles").font(.caption).foregroundStyle(.secondary)
                    if record.kind == .reading, let result = try? ReadingComparison.parse(record.resultJSON, materials: materials) {
                        ReadingComparisonResultView(result: result, materials: materials, record: record)
                    } else if record.kind == .conditions, let result = try? ConditionExploration.parse(record.resultJSON, solution: record.inputText) {
                        ConditionExplorationResultView(result: result)
                    } else if let result = try? SolutionComparison.parse(record.resultJSON, ownSolution: record.inputText) {
                        ComparisonResultView(result: result)
                    }
                }
                if record.inputTokens > 0 || record.outputTokens > 0 {
                    Text("累计输入 \(record.inputTokens) · 输出 \(record.outputTokens) token" + (record.costCNY.map { " · 约 ¥" + String(format: "%.4f", $0) } ?? ""))
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            .padding()
        }
        .navigationTitle(record.kind?.title ?? "学习探索").navigationBarTitleDisplayMode(.inline)
        .groupedPageBackground()
        .sheet(item: $selection) { material in StudyMaterialSheet(material: material) }
        .task {
            do {
                materials = try record.materials()
                model = (try context.fetch(FetchDescriptor<ChatModel>())).first { $0.id == record.modelID } ?? ModelLookup.defaultModel(in: context)
                try InvestigationRunner.recover(record, context: context)
                if autoStart && record.statusRaw == "draft" { start() }
            } catch { errorText = ChatErrorDescription.describe(error) }
        }
        .onDisappear { task?.cancel() }
        .studyError($errorText)
    }

    private var generationControls: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let error = record.errorText { Text(error).foregroundStyle(.red).font(.subheadline) }
            if runner.isRunning {
                HStack {
                    ProgressView()
                    Text("正在分析 · \(runner.characterCount) 字").font(.subheadline)
                    Spacer()
                    Button("停止") { task?.cancel() }
                }
            } else {
                HStack {
                    ModelPickerMenu(selection: $model)
                    Spacer()
                    Button(record.resultJSON.isEmpty ? "开始分析" : "重新分析", action: start).disabled(model == nil)
                }
            }
        }
    }

    private func start() {
        guard let model, !runner.isRunning else { return }
        do {
            let prepared = try InvestigationWorkflow.prepare(record: record, model: model)
            let service = try ModelLookup.service(for: model)
            task = Task {
                do {
                    try await runner.run(record: record, request: prepared.request, model: model, context: context, service: service, validate: prepared.validate)
                } catch { if !Task.isCancelled { errorText = ChatErrorDescription.describe(error) } }
            }
        } catch { errorText = ChatErrorDescription.describe(error) }
    }
}

struct ComparisonResultView: View {
    let result: SolutionComparison.Result
    @Environment(\.horizontalSizeClass) private var sizeClass
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            if sizeClass == .compact { Text("左右滑动查看各解法，按共同目标逐行对照。").font(.caption).foregroundStyle(.secondary) }
            ScrollView(.horizontal) {
                Grid(alignment: .topLeading, horizontalSpacing: 12, verticalSpacing: 14) {
                    GridRow {
                        Text("共同目标").font(.headline).frame(width: 100, alignment: .leading)
                        ForEach(result.methods.indices, id: \.self) { index in
                            Text(result.methods[index].title + (result.methods[index].origin == "user" ? "（自己的解法）" : ""))
                                .font(.headline).frame(width: 270, alignment: .leading)
                        }
                    }
                    ForEach(result.rows.indices, id: \.self) { row in
                        GridRow {
                            Text(result.rows[row].goal).font(.subheadline.bold()).frame(width: 100, alignment: .leading)
                            ForEach(result.methods.indices, id: \.self) { column in
                                VStack(alignment: .leading, spacing: 10) {
                                    if let cell = result.rows[row].cells[column] {
                                        StudyMarkdown(content: cell.text)
                                        if !cell.conditions.isEmpty { Text("使用条件：" + cell.conditions.joined(separator: "；")).font(.caption) }
                                        if !cell.keyIdea.isEmpty { Text("关键转折：" + cell.keyIdea).font(.caption).foregroundStyle(.tint) }
                                        if !cell.detour.isEmpty { Text("检查步骤：" + cell.detour).font(.caption).foregroundStyle(.orange) }
                                        if !cell.originalQuote.isEmpty { Text("原解法：“\(cell.originalQuote)”").font(.caption).foregroundStyle(.secondary) }
                                    } else { Text("无对应步骤").foregroundStyle(.secondary) }
                                }
                                .padding(12).frame(width: 270, alignment: .leading).groupedCardBackground()
                            }
                        }
                    }
                }
                .padding(.bottom, 6)
            }
            StudyMarkdown(content: result.conclusion)
        }
        .accessibilityIdentifier("solution-comparison-result")
    }
}

struct StudyMarkdown: View {
    let content: String
    @State private var identity = UUID()
    @State private var height: CGFloat = 60
    var body: some View {
        MessageWebView(messageID: identity, content: content, isStreaming: false, height: $height, groupedSurface: true)
            .frame(height: height)
    }
}

struct StudyMaterialSheet: View {
    let material: StudyMaterial
    var evidence: ReadingComparison.Evidence?
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        NavigationStack {
            ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    if let reference = material.reference { StudyReferenceStrip(references: [reference]) }
                    if !material.location.isEmpty { Text(material.location).font(.caption).textSelection(.enabled) }
                    if let evidence {
                        let lines = material.content.components(separatedBy: "\n")
                        LazyVStack(alignment: .leading, spacing: 8) {
                            ForEach(lines.indices, id: \.self) { index in
                                HStack(alignment: .top, spacing: 10) {
                                    Text("\(index + 1)").font(.caption.monospacedDigit()).foregroundStyle(.secondary).frame(width: 30)
                                    Text(lines[index].isEmpty ? " " : lines[index]).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                                }
                                .padding(8)
                                .background(index + 1 >= evidence.startLine && index + 1 <= evidence.endLine ? Color.accentColor.opacity(0.15) : Color.clear)
                                .id(index + 1)
                            }
                        }
                    } else { StudyMarkdown(content: displayContent) }
                    ForEach(material.images.indices, id: \.self) { index in
                        if let image = UIImage(data: material.images[index].data) {
                            Image(uiImage: image).resizable().scaledToFit().accessibilityLabel("原材料附件 \(index + 1)")
                        }
                    }
                }.padding()
            }
            .task { if let evidence { proxy.scrollTo(evidence.startLine, anchor: .center) } }
            }
            .navigationTitle(material.title).navigationBarTitleDisplayMode(.inline)
            .toolbar { Button("完成") { dismiss() } }
        }
    }

    private var displayContent: String {
        material.images.enumerated().reduce(material.content) { text, pair in
            guard let id = pair.element.assetID else { return text }
            // 附件按快照显示，避免原记录删除后仍请求其资源地址。
            let pattern = #"!\[[^\]]*\]\(sa-asset:"# + id.uuidString + #"(?:\s+\"[^\"]*\")?\)"#
            return text.replacingOccurrences(of: pattern, with: "（见附件 \(pair.offset + 1)）", options: [.regularExpression, .caseInsensitive])
        }
    }
}
