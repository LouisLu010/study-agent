import StudyKit
import SwiftData
import SwiftUI

struct ConditionExplorationComposer: View {
    @Environment(\.modelContext) private var context
    @State private var material: StudyMaterial?
    @State private var original = ""
    @State private var operation = ConditionExploration.Operation.replace
    @State private var fragment = ""
    @State private var replacement = ""
    @State private var solution = ""
    @State private var model: ChatModel?
    @State private var choosing = false
    @State private var created: StudyInvestigation?
    @State private var errorText: String?

    private var source: StudyMaterial { material ?? .init(title: String(original.prefix(40)), content: original) }
    private var change: ConditionExploration.Change { .init(operation: operation, fragment: fragment, replacement: replacement) }
    private var preview: Result<StudyMaterial, any Error> { Result { try ConditionExploration.variant(original: source, change: change) } }

    var body: some View {
        Form {
            Section("原题") {
                Button("选择已有内容", systemImage: "books.vertical") { choosing = true }
                if let material {
                    Text(material.title).font(.headline)
                    Text(material.content).textSelection(.enabled)
                    Button("重新输入原题") { self.material = nil; original = "" }
                } else { TextEditor(text: $original).frame(minHeight: 120).accessibilityLabel("原题") }
            }
            Section("只改一个条件") {
                Picker("操作", selection: $operation) { ForEach(ConditionExploration.Operation.allCases, id: \.self) { Text($0.title).tag($0) } }
                TextField("从原题复制要修改的条件", text: $fragment, axis: .vertical).lineLimit(2...6)
                if operation == .replace { TextField("新条件", text: $replacement, axis: .vertical).lineLimit(2...6) }
            }
            Section("变式预览") {
                switch preview {
                case let .success(value): Text(value.content).textSelection(.enabled)
                case let .failure(error): Text(error.localizedDescription).foregroundStyle(.secondary)
                }
            }
            Section("原解法（可选）") {
                TextEditor(text: $solution).frame(minHeight: 100).accessibilityLabel("原解法")
            }
            Section {
                ModelPickerMenu(selection: $model)
                Button("保存并探索", action: create).disabled(model == nil || (try? preview.get()) == nil)
                Text("原题、变式和原解法会发给模型；分析与反例标明为 AI 推演。原记录保持完整。")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .navigationTitle("条件探索")
        .sheet(isPresented: $choosing) { StudyMaterialPicker { material = $0; fragment = ""; replacement = "" } }
        .navigationDestination(item: $created) { InvestigationDetailView(record: $0, autoStart: true) }
        .task { model = ModelLookup.defaultModel(in: context) }
        .studyError($errorText)
    }

    private func create() {
        guard let model else { return }
        do {
            let source = source, variant = try preview.get()
            let request = try ConditionExploration.request(model: model.modelID, original: source, change: change, solution: solution)
            _ = try InvestigationRunner.attachImages([source], to: request, model: model)
            let record = StudyInvestigation(kind: .conditions, title: source.title)
            try record.setMaterials([source, variant]); record.inputText = solution
            record.detailJSON = try StudyToolJSON.encode(change); record.modelID = model.id
            context.insert(record)
            do { try context.save() } catch { context.delete(record); throw error }
            created = record
        } catch { errorText = ChatErrorDescription.describe(error) }
    }
}

struct ConditionExplorationResultView: View {
    let result: ConditionExploration.Result
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            ForEach(result.steps.indices, id: \.self) { index in
                let step = result.steps[index]
                VStack(alignment: .leading, spacing: 8) {
                    Text("步骤 \(index + 1) · \(step.status.title)").font(.headline)
                    StudyMarkdown(content: step.originalStep + "\n\n" + step.reason)
                    if !step.sourceQuote.isEmpty { Text("原解法：“\(step.sourceQuote)”").font(.caption).foregroundStyle(.secondary) }
                    if !step.revisedStep.isEmpty { StudyMarkdown(content: "调整：" + step.revisedStep) }
                }.padding().groupedCardBackground()
            }
            Text("反例检查 · AI 推演").font(.headline)
            Text(counterexampleTitle).font(.subheadline).foregroundStyle(.secondary)
            StudyMarkdown(content: result.counterexample.candidate + "\n\n" + result.counterexample.verification)
            StudyMarkdown(content: result.conclusion)
        }
    }

    private var counterexampleTitle: String {
        switch result.counterexample.status {
        case .found: "提出一个反例，请结合下面的代入过程核对。"
        case .notFound: "本次未找到反例，不代表已经证明成立。"
        case .uncertain: "目前不能确定反例是否成立。"
        }
    }
}
