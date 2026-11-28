import StudyKit
import SwiftData
import SwiftUI

private enum ReadingSourceSheet: String, Identifiable { case existing, text; var id: String { rawValue } }

struct ReadingComparisonComposer: View {
    @Environment(\.modelContext) private var context
    @State private var concept = ""
    @State private var materials: [StudyMaterial] = []
    @State private var sheet: ReadingSourceSheet?
    @State private var model: ChatModel?
    @State private var created: StudyInvestigation?
    @State private var errorText: String?

    var body: some View {
        Form {
            Section("要比较的概念") { TextField("例如：导数的定义", text: $concept) }
            Section("两至四份原文") {
                ForEach(materials) { material in
                    VStack(alignment: .leading, spacing: 6) {
                        Text(material.title).font(.headline)
                        Text(material.location).font(.caption).foregroundStyle(.secondary)
                        Text(material.content).lineLimit(4).font(.subheadline)
                    }
                }
                .onDelete { materials.remove(atOffsets: $0) }
                if materials.count < 4 {
                    Button("选择已有内容", systemImage: "books.vertical") { sheet = .existing }
                    Button("粘贴教材或讲义", systemImage: "doc.on.clipboard") { sheet = .text }
                }
                Text("图片可以随材料保留；比较依据必须来自可定位的文字。扫描教材请先提供原文，并注明页码或章节。")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section {
                ModelPickerMenu(selection: $model)
                Button("保存并对照", action: create).disabled(materials.count < 2 || model == nil || concept.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                Text("所选文字会发送给模型。每个判断附原文证据，理解草稿经过你确认后才保存为知识卡。")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .navigationTitle("资料对照阅读")
        .sheet(item: $sheet) { route in
            switch route {
            case .existing: StudyMaterialPicker { materials.append($0) }
            case .text: ReadingSourceEditor { materials.append($0) }
            }
        }
        .navigationDestination(item: $created) { InvestigationDetailView(record: $0, autoStart: true) }
        .task { model = ModelLookup.defaultModel(in: context) }
        .studyError($errorText)
    }

    private func create() {
        guard let model else { return }
        do {
            _ = try ReadingComparison.request(model: model.modelID, concept: concept, materials: materials)
            let record = StudyInvestigation(kind: .reading, title: concept)
            try record.setMaterials(materials); record.inputText = concept; record.modelID = model.id
            context.insert(record)
            do { try context.save() } catch { context.delete(record); throw error }
            created = record
        } catch { errorText = ChatErrorDescription.describe(error) }
    }
}

private struct ReadingSourceEditor: View {
    let onSave: (StudyMaterial) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var title = ""
    @State private var location = ""
    @State private var content = ""
    var body: some View {
        NavigationStack {
            Form {
                TextField("材料名称", text: $title)
                TextField("页码、章节或段落位置", text: $location)
                TextEditor(text: $content).frame(minHeight: 260).accessibilityLabel("原文")
                Text("保留原文换行，便于逐行核对。").font(.caption).foregroundStyle(.secondary)
            }
            .navigationTitle("添加原文")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) { Button("添加") {
                    onSave(.init(title: title, content: content, location: location)); dismiss()
                }.disabled(!StudyToolJSON.nonempty(title, max: 200) || !StudyToolJSON.nonempty(content, max: 30_000) || !StudyToolJSON.nonempty(location, max: 500)) }
            }
        }
    }
}

private struct ReadingEvidenceSelection: Identifiable {
    let id = UUID()
    let material: StudyMaterial
    let evidence: ReadingComparison.Evidence
}

struct ReadingComparisonResultView: View {
    let result: ReadingComparison.Result
    let materials: [StudyMaterial]
    var record: StudyInvestigation?
    @State private var selection: ReadingEvidenceSelection?
    @State private var saving = false

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            ForEach(result.comparisons.indices, id: \.self) { index in
                let comparison = result.comparisons[index]
                VStack(alignment: .leading, spacing: 12) {
                    Text(comparison.aspect.title + " · " + comparison.agreement.title).font(.headline)
                    StudyMarkdown(content: comparison.explanation)
                    ForEach(comparison.evidence) { evidence in
                        if let material = materials.first(where: { $0.id == evidence.sourceID }) {
                            Button { selection = .init(material: material, evidence: evidence) } label: {
                                VStack(alignment: .leading, spacing: 6) {
                                    Text(material.title + " · 第 \(evidence.startLine)–\(evidence.endLine) 行").font(.caption.bold())
                                    Text("“\(evidence.quote)”").font(.subheadline).multilineTextAlignment(.leading)
                                    Label("定位原文", systemImage: "arrow.up.right").font(.caption)
                                }.frame(maxWidth: .infinity, alignment: .leading)
                            }.buttonStyle(.plain)
                        }
                    }
                }.padding().groupedCardBackground()
            }
            Text("理解草稿").font(.headline)
            StudyMarkdown(content: result.synthesis)
            if record != nil {
                Button("核对并保存知识卡", systemImage: "rectangle.stack.badge.plus") { saving = true }
                    .buttonStyle(.borderedProminent)
                    .disabled(result.comparisons.allSatisfy { $0.evidence.isEmpty })
            }
        }
        .sheet(item: $selection) { selection in StudyMaterialSheet(material: selection.material, evidence: selection.evidence) }
        .sheet(isPresented: $saving) {
            if let record { ReadingCardDraftSheet(record: record, synthesis: result.synthesis) }
        }
    }
}

private struct ReadingCardDraftSheet: View {
    let record: StudyInvestigation
    let synthesis: String
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @Environment(AppNavigation.self) private var navigation
    @State private var title = ""
    @State private var content = ""
    @State private var subject = Subject.other
    @State private var confirmed = false
    @State private var expectedResult: String?
    @State private var errorText: String?
    var body: some View {
        NavigationStack {
            Form {
                TextField("标题", text: $title)
                Picker("科目", selection: $subject) { ForEach(Subject.allCases) { Text($0.rawValue).tag($0) } }
                TextEditor(text: $content).frame(minHeight: 240).accessibilityLabel("确认后的理解")
                Toggle("已核对原文与适用条件", isOn: $confirmed)
                Text("知识卡会保留原文快照、引用片段和位置。可以先修改以上理解再保存。")
                    .font(.caption).foregroundStyle(.secondary)
            }
            .navigationTitle("确认知识卡")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) { Button("保存") {
                    do {
                        _ = try ReadingComparisonStore.saveCard(record: record, title: title, content: content, subject: subject, context: context, expectedResult: expectedResult)
                        navigation.selection = .notes; dismiss()
                    } catch { errorText = ChatErrorDescription.describe(error) }
                }.disabled(!confirmed || !StudyToolJSON.nonempty(title, max: 100) || !StudyToolJSON.nonempty(content, max: 20_000)) }
            }
            .onAppear {
                if expectedResult == nil { title = record.inputText; content = synthesis; expectedResult = record.resultJSON }
            }
            .studyError($errorText)
        }
    }
}

struct ReadingCardEvidenceSheet: View {
    let card: ConceptCard
    @Environment(\.dismiss) private var dismiss
    @State private var bundles: [ReadingComparison.SourceBundle] = []
    @State private var errorText: String?
    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    ForEach(bundles) { bundle in ReadingComparisonResultView(result: bundle.result, materials: bundle.materials) }
                }.padding()
            }
            .navigationTitle("对照阅读原文").navigationBarTitleDisplayMode(.inline)
            .toolbar { Button("完成") { dismiss() } }
            .task {
                do { bundles = try ReadingComparisonStore.bundles(card) }
                catch { errorText = "读取原文失败，请重试。" }
            }
            .studyError($errorText)
        }
    }
}
