import StudyKit
import SwiftData
import SwiftUI

struct KnowledgeGapComposer: View {
    @Environment(\.modelContext) private var context
    @Environment(ToastCenter.self) private var toasts
    @Query(sort: \ConceptCard.updatedAt, order: .reverse) private var cards: [ConceptCard]
    @State private var query = ""
    @State private var target: ConceptCard?
    @State private var materials: [StudyMaterial] = []
    @State private var session: KnowledgeGap.Session?
    @State private var model: ChatModel?
    @State private var created: StudyInvestigation?
    @State private var errorText: String?

    var body: some View {
        Form {
            Section("想检查哪个概念") {
                TextField("搜索知识卡", text: $query)
                ForEach(cards.filter { !toasts.isHidden($0) && (query.isEmpty || $0.title.localizedStandardContains(query)) }) { card in
                    Button {
                        do {
                            let prepared = try KnowledgeGapStore.prepare(target: card, context: context, hiddenIDs: toasts.hiddenIDs)
                            target = card; materials = prepared.materials; session = prepared.session
                        } catch { errorText = ChatErrorDescription.describe(error) }
                    } label: {
                        HStack { Text(card.title); Spacer(); if target?.id == card.id { Image(systemName: "checkmark") } }
                    }
                }
                if cards.isEmpty { Text("先在资料中整理知识卡和前置关联。").foregroundStyle(.secondary) }
            }
            if target != nil {
                Section("这次检查的范围") {
                    ForEach(materials) { material in
                        VStack(alignment: .leading) {
                            Text(material.title)
                            Text(material.location).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    Text(materials.count == 1 ? "没有找到有效的前置关联，这次只检查目标概念。" : "沿前置关联最多回溯三步，最多检查五个概念。")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            Section {
                ModelPickerMenu(selection: $model)
                Button("生成检查题", action: create).disabled(target == nil || model == nil)
                Text("选中的知识卡会发送给模型。实际作答后才生成建议，结果只代表本次检查。")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .navigationTitle("知识缺口定位")
        .navigationDestination(item: $created) { KnowledgeGapDetailView(record: $0, autoStart: true) }
        .task { model = ModelLookup.defaultModel(in: context) }
        .studyError($errorText)
    }

    private func create() {
        guard let target, let model else { return }
        do {
            // 用户确认时重新检查，避免保存已经删除或撤回的关联。
            let prepared = try KnowledgeGapStore.prepare(target: target, context: context, hiddenIDs: toasts.hiddenIDs)
            let request = try KnowledgeGap.planRequest(model: model.modelID, materials: prepared.materials, nodes: prepared.session.nodes)
            _ = try InvestigationRunner.attachImages(prepared.materials, to: request, model: model)
            let record = StudyInvestigation(kind: .gaps, title: target.title)
            try record.setMaterials(prepared.materials)
            record.detailJSON = try StudyToolJSON.encode(prepared.session); record.modelID = model.id
            context.insert(record)
            do { try context.save() } catch { context.delete(record); throw error }
            created = record
        } catch { errorText = ChatErrorDescription.describe(error) }
    }
}

struct KnowledgeGapDetailView: View {
    let record: StudyInvestigation
    var autoStart = false
    @Environment(\.modelContext) private var context
    @State private var materials: [StudyMaterial] = []
    @State private var session: KnowledgeGap.Session?
    @State private var selection: StudyMaterial?
    @State private var model: ChatModel?
    @State private var runner = InvestigationRunner()
    @State private var task: Task<Void, Never>?
    @State private var errorText: String?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                Text(record.title).font(.title2.bold())
                Text("这次检查只根据下方作答提供建议。未作答或依据不足时，不判断是否掌握。")
                    .font(.subheadline).foregroundStyle(.secondary)
                ForEach(materials) { material in
                    Button { selection = material } label: { Text(material.location).font(.caption) }
                }
                if let plan = session?.plan {
                    ForEach(plan.questions) { question in questionView(question) }
                }
                if let error = record.errorText { Text(error).foregroundStyle(.red) }
                if runner.isRunning {
                    HStack { ProgressView(); Text("正在分析 · \(runner.characterCount) 字"); Button("停止") { task?.cancel() } }
                } else {
                    ModelPickerMenu(selection: $model)
                    Button(session?.plan == nil ? "生成检查题" : "根据作答分析", action: start).buttonStyle(.borderedProminent).disabled(model == nil)
                }
                if let session, !record.resultJSON.isEmpty,
                   let assessment = try? KnowledgeGap.parseAssessment(record.resultJSON, session: session) {
                    Label("AI 建议 · \(record.modelName)", systemImage: "sparkles").font(.caption)
                    ForEach(assessment.findings) { finding in
                        VStack(alignment: .leading, spacing: 10) {
                            Text((materials.first { $0.id == finding.conceptID }?.title ?? "概念") + " · " + finding.verdict.title).font(.headline)
                            if !finding.evidenceQuote.isEmpty { Text("作答证据：“\(finding.evidenceQuote)”").font(.subheadline) }
                            StudyMarkdown(content: finding.reason + "\n\n下一步：" + finding.nextStep)
                            if let question = session.plan?.questions.first(where: { $0.conceptID == finding.conceptID }) {
                                DisclosureGroup("参考答案与作答要点") { StudyMarkdown(content: question.referenceAnswer + "\n\n" + question.rubric) }
                            }
                            if let material = materials.first(where: { $0.id == finding.conceptID }) {
                                Button("返回知识卡与原文") { selection = material }
                            }
                        }.padding().groupedCardBackground()
                    }
                }
                InvestigationUsage(record: record)
            }.padding()
        }
        .navigationTitle("知识缺口定位").navigationBarTitleDisplayMode(.inline)
        .groupedPageBackground()
        .sheet(item: $selection) { StudyMaterialSheet(material: $0) }
        .task {
            do {
                materials = try record.materials()
                session = try StudyToolJSON.decode(KnowledgeGap.Session.self, from: record.detailJSON)
                model = (try context.fetch(FetchDescriptor<ChatModel>())).first { $0.id == record.modelID } ?? ModelLookup.defaultModel(in: context)
                try InvestigationRunner.recover(record, context: context)
                if autoStart && session?.plan == nil && record.statusRaw == "draft" { start() }
            } catch { errorText = ChatErrorDescription.describe(error) }
        }
        .onDisappear { task?.cancel() }
        .studyError($errorText)
    }

    private func questionView(_ question: KnowledgeGap.Question) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(materials.first { $0.id == question.conceptID }?.title ?? "检查题").font(.headline)
            StudyMarkdown(content: question.prompt)
            TextField("写下你的回答和理由", text: Binding(get: { session?.answers[question.conceptID.uuidString] ?? "" }, set: { value in
                do {
                    try KnowledgeGapStore.answer(value, conceptID: question.conceptID, record: record, context: context)
                    session?.answers[question.conceptID.uuidString] = value
                } catch { errorText = ChatErrorDescription.describe(error) }
            }), axis: .vertical).lineLimit(3...8).textFieldStyle(.roundedBorder).disabled(runner.isRunning)
        }.padding().groupedCardBackground()
    }

    private func start() {
        guard let model, let snapshot = session, !runner.isRunning else { return }
        do {
            let planning = snapshot.plan == nil
            let request = planning
                ? try KnowledgeGap.planRequest(model: model.modelID, materials: materials, nodes: snapshot.nodes, reasoning: model.reasoningEffort)
                : try KnowledgeGap.assessmentRequest(model: model.modelID, session: snapshot, materials: materials, reasoning: model.reasoningEffort)
            let prepared = try InvestigationRunner.attachImages(materials, to: request, model: model)
            let service = try ModelLookup.service(for: model)
            task = Task {
                do {
                    try await runner.run(record: record, request: prepared, model: model, context: context, service: service, savesDetail: planning) { raw in
                        if planning {
                            var next = snapshot
                            next.plan = try KnowledgeGap.parsePlan(raw, conceptIDs: Set(snapshot.nodes.map(\.id)))
                            return try StudyToolJSON.encode(next)
                        }
                        return try StudyToolJSON.encode(KnowledgeGap.parseAssessment(raw, session: snapshot))
                    }
                    session = try StudyToolJSON.decode(KnowledgeGap.Session.self, from: record.detailJSON)
                } catch { if !Task.isCancelled { errorText = ChatErrorDescription.describe(error) } }
            }
        } catch { errorText = ChatErrorDescription.describe(error) }
    }
}

struct InvestigationUsage: View {
    let record: StudyInvestigation
    var body: some View {
        if record.inputTokens > 0 || record.outputTokens > 0 {
            Text("累计输入 \(record.inputTokens) · 输出 \(record.outputTokens) token" + (record.costCNY.map { " · 约 ¥" + String(format: "%.4f", $0) } ?? ""))
                .font(.caption).foregroundStyle(.secondary)
        }
    }
}
