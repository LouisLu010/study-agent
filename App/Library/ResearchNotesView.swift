import StudyKit
import SwiftData
import SwiftUI

/// 要整理成资料的内容，用来驱动 `.sheet(item:)`。
struct NoteDraftRequest: Identifiable {
    let id = UUID()
    let items: [ResearchNoteWriter.Item]
    let fallbackTitle: String
    let model: ChatModel?
    let conversationID: UUID?

    /// 整个会话。
    static func conversation(_ conversation: Conversation) -> NoteDraftRequest {
        NoteDraftRequest(
            items: conversation.sortedMessages.map(item(for:)),
            fallbackTitle: conversation.title,
            model: conversation.model,
            conversationID: conversation.id
        )
    }

    /// 一条回答，连同它前面那条提问。
    static func reply(_ message: Message) -> NoteDraftRequest {
        let conversation = message.conversation
        let question = conversation?.sortedMessages.last { $0.role == .user && $0.index < message.index }
        return NoteDraftRequest(
            items: [question, message].compactMap { $0 }.map(item(for:)),
            fallbackTitle: conversation?.title ?? "资料",
            model: conversation?.model,
            conversationID: conversation?.id
        )
    }

    private static func item(for message: Message) -> ResearchNoteWriter.Item {
        var content = message.content
        if message.role == .user, !message.imageData.isEmpty {
            content = "（附了 \(message.imageData.count) 张图片）\n" + content
        }
        return ResearchNoteWriter.Item(
            role: message.role,
            content: content,
            sources: message.webSearch?.displayedSources ?? []
        )
    }
}

/// 让模型整理资料，预览后保存。
struct NoteDraftSheet: View {
    let request: NoteDraftRequest

    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @State private var raw = ""
    @State private var isGenerating = false
    @State private var errorText: String?
    @State private var task: Task<Void, Never>?
    @State private var height: CGFloat = 60
    @State private var previewID = UUID()
    private let prepared: (text: String, sources: [WebSource])

    init(request: NoteDraftRequest) {
        self.request = request
        self.prepared = ResearchNoteWriter.prepare(request.items)
    }

    private var draft: ResearchNoteWriter.Draft {
        ResearchNoteWriter.parse(raw, sources: prepared.sources, fallbackTitle: request.fallbackTitle)
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    if let errorText {
                        Label(errorText, systemImage: "exclamationmark.triangle")
                            .foregroundStyle(.red)
                    }
                    if raw.isEmpty && isGenerating {
                        HStack(spacing: 8) {
                            ProgressView()
                            Text("正在整理…").foregroundStyle(.secondary)
                        }
                    }
                    if !raw.isEmpty {
                        let draft = draft
                        Text(draft.title).font(.title3.bold())
                        Text([draft.subject?.rawValue ?? "", draft.topic].filter { !$0.isEmpty }.joined(separator: " · "))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        MessageWebView(
                            messageID: previewID,
                            content: draft.content,
                            isStreaming: isGenerating,
                            height: $height
                        )
                        .frame(height: height)
                        if !isGenerating && !draft.sources.isEmpty {
                            SourceListView(sources: draft.sources, numbered: true)
                        }
                    }
                }
                .padding()
                .frame(maxWidth: 820)
                .frame(maxWidth: .infinity)
            }
            .navigationTitle("整理成资料")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") {
                        task?.cancel()
                        dismiss()
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存", action: save)
                        .disabled(isGenerating || draft.content.isEmpty)
                }
                ToolbarItem(placement: .bottomBar) {
                    Button("重新整理", systemImage: "arrow.clockwise", action: start)
                        .disabled(isGenerating)
                }
            }
        }
        .task { start() }
        .onDisappear { task?.cancel() }
    }

    private func start() {
        task?.cancel()
        raw = ""
        errorText = nil
        previewID = UUID()
        guard let model = request.model else {
            errorText = GenerationError.noModel.localizedDescription
            return
        }
        let service: any ChatService
        do {
            service = try ModelLookup.service(for: model)
        } catch {
            errorText = ChatErrorDescription.describe(error)
            return
        }
        let chatRequest = ChatRequest(
            model: model.modelID,
            systemPrompt: SystemPrompt.compose(
                customInstructions: "",
                conversationInstructions: ResearchNoteWriter.instructions,
                simpleMode: UserDefaults.standard.bool(forKey: AppSettingsKey.simpleMode)
            ),
            messages: [ChatMessage(role: .user, text: prepared.text)],
            reasoningEffort: model.reasoningEffort
        )
        isGenerating = true
        task = Task {
            do {
                for try await event in service.streamChat(chatRequest) {
                    if case let .text(delta) = event { raw += delta }
                }
            } catch {
                if !Task.isCancelled { errorText = ChatErrorDescription.describe(error) }
            }
            isGenerating = false
        }
    }

    private func save() {
        let draft = draft
        let note = ResearchNote(title: draft.title, content: draft.content)
        note.subject = draft.subject ?? .other
        note.topic = draft.topic.isEmpty ? "未分类" : draft.topic
        note.sources = draft.sources
        note.modelName = request.model?.name ?? ""
        note.sourceConversationID = request.conversationID
        context.insert(note)
        try? context.save()
        dismiss()
    }
}

/// 资料列表：按科目分节，节里按知识点排。
struct ResearchNotesView: View {
    @Environment(\.modelContext) private var context
    @Query(sort: \ResearchNote.updatedAt, order: .reverse) private var notes: [ResearchNote]
    @State private var subject: Subject?
    @State private var searchText = ""

    private var filtered: [ResearchNote] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        return notes.filter { note in
            if let subject, note.subject != subject { return false }
            guard !query.isEmpty else { return true }
            return note.title.localizedStandardContains(query)
                || note.topic.localizedStandardContains(query)
                || note.content.localizedStandardContains(query)
        }
    }

    /// 科目 → 知识点 → 资料。
    private var groups: [(subject: Subject, topics: [(topic: String, notes: [ResearchNote])])] {
        Subject.allCases.compactMap { subject in
            let inSubject = filtered.filter { ($0.subject ?? .other) == subject }
            guard !inSubject.isEmpty else { return nil }
            let topics = Dictionary(grouping: inSubject) { $0.topic.isEmpty ? "未分类" : $0.topic }
                .map { (topic: $0.key, notes: $0.value) }
                .sorted { $0.topic.localizedStandardCompare($1.topic) == .orderedAscending }
            return (subject, topics)
        }
    }

    private var subjects: [Subject] {
        let present = Set(notes.map { $0.subject ?? .other })
        return Subject.allCases.filter(present.contains)
    }

    var body: some View {
        List {
            if subjects.count > 1 {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        SubjectChip(title: "全部科目", isSelected: subject == nil) { subject = nil }
                        ForEach(subjects) { item in
                            SubjectChip(title: item.rawValue, isSelected: subject == item) { subject = item }
                        }
                    }
                }
                .listRowSeparator(.hidden)
            }
            ForEach(groups, id: \.subject) { group in
                Section(group.subject.rawValue) {
                    ForEach(group.topics, id: \.topic) { topic in
                        Text(topic.topic)
                            .font(.caption.bold())
                            .foregroundStyle(.secondary)
                            .listRowSeparator(.hidden)
                        ForEach(topic.notes) { note in
                            NavigationLink {
                                ResearchNoteDetailView(note: note)
                            } label: {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(note.title).lineLimit(1)
                                    Text(PlainTextExporter.plainText(from: note.content).prefix(120))
                                        .font(.callout)
                                        .foregroundStyle(.secondary)
                                        .lineLimit(2)
                                    Text(note.updatedAt.formatted(.dateTime.month().day()) + (note.sources.isEmpty ? "" : " · \(note.sources.count) 个出处"))
                                        .font(.caption)
                                        .foregroundStyle(.tertiary)
                                }
                                .padding(.vertical, 2)
                            }
                            .swipeActions {
                                Button("删除", systemImage: "trash", role: .destructive) {
                                    context.delete(note)
                                    try? context.save()
                                }
                            }
                        }
                    }
                }
            }
        }
        .overlay {
            if notes.isEmpty {
                ContentUnavailableView(
                    "还没有资料",
                    systemImage: "doc.text.magnifyingglass",
                    description: Text("在会话标题菜单或回答下方点\"整理成资料\"，模型会把内容和出处整理成一份总结保存到这里。")
                )
            } else if filtered.isEmpty {
                ContentUnavailableView.search(text: searchText)
            }
        }
        .searchable(text: $searchText, prompt: "搜索资料")
        .navigationTitle("资料")
    }
}

/// 一份资料：显示、编辑原文、删出处、导出。
struct ResearchNoteDetailView: View {
    @Bindable var note: ResearchNote

    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @Environment(AppNavigation.self) private var navigation
    @State private var isEditing = false
    @State private var showsPreview = false
    @State private var draftText = ""
    @State private var draftSources: [WebSource] = []
    @State private var previewID = UUID()
    @State private var shareItem: ShareItem?
    @State private var errorMessage: String?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Picker("科目", selection: Binding(get: { note.subject ?? .other }, set: { note.subject = $0 })) {
                        ForEach(Subject.allCases) { Text($0.rawValue).tag($0) }
                    }
                    .labelsHidden()
                    TextField("知识点", text: $note.topic)
                        .textFieldStyle(.roundedBorder)
                }
                if isEditing {
                    TextField("标题", text: $note.title)
                        .textFieldStyle(.roundedBorder)
                    Picker("", selection: $showsPreview) {
                        Text("原文").tag(false)
                        Text("预览").tag(true)
                    }
                    .pickerStyle(.segmented)
                    if showsPreview {
                        RenderedContentView(id: previewID, content: draftText)
                    } else {
                        TextEditor(text: $draftText)
                            .font(.system(.callout, design: .monospaced))
                            .frame(minHeight: 420)
                            .scrollContentBackground(.hidden)
                            .padding(6)
                            .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 10))
                    }
                    if !draftSources.isEmpty {
                        SourceListView(sources: draftSources, numbered: true) { index in
                            let result = ResearchNoteWriter.removeSource(at: index, sources: draftSources, content: draftText)
                            draftSources = result.sources
                            draftText = result.content
                        }
                    }
                } else {
                    RenderedContentView(
                        id: note.id,
                        content: note.content,
                        componentStateJSON: note.componentStateJSON,
                        onComponentState: { key, state in
                            note.componentStateJSON = ComponentStateStore.updating(note.componentStateJSON, key: key, state: state)
                            try? context.save()
                        }
                    )
                    if !note.sources.isEmpty {
                        SourceListView(sources: note.sources, numbered: true)
                    }
                    Text(footer)
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
            }
            .padding()
            .frame(maxWidth: 820)
            .frame(maxWidth: .infinity)
        }
        .navigationTitle(note.title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if isEditing {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { isEditing = false }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成", action: finishEditing)
                }
            } else {
                ToolbarItem(placement: .primaryAction) {
                    Menu {
                        Button("编辑", systemImage: "pencil", action: startEditing)
                        Button("复制", systemImage: "doc.on.doc") {
                            UIPasteboard.general.string = plainText
                        }
                        Button("导出为 Markdown", systemImage: "square.and.arrow.up", action: export)
                        if note.sourceConversationID != nil {
                            Button("查看原会话", systemImage: "bubble.left.and.text.bubble.right") {
                                if !navigation.open(conversationID: note.sourceConversationID, in: context) {
                                    errorMessage = "原会话已经删除了。"
                                }
                            }
                        }
                        Button("删除资料", systemImage: "trash", role: .destructive) {
                            context.delete(note)
                            try? context.save()
                            dismiss()
                        }
                    } label: {
                        Image(systemName: "ellipsis.circle")
                    }
                }
            }
        }
        .onChange(of: showsPreview) { previewID = UUID() }
        .onDisappear { try? context.save() }
        .sheet(item: $shareItem) { item in
            ShareSheet(items: item.items)
                .presentationDetents([.medium, .large])
        }
        .alert("提示", isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })) {
            Button("好", role: .cancel) {}
        } message: {
            Text(errorMessage ?? "")
        }
    }

    private var footer: String {
        var parts: [String] = []
        if !note.modelName.isEmpty { parts.append("由 \(note.modelName) 整理") }
        parts.append("更新于 \(note.updatedAt.formatted(date: .abbreviated, time: .shortened))")
        return parts.joined(separator: " · ")
    }

    private var sourcesText: String {
        guard !note.sources.isEmpty else { return "" }
        let lines = note.sources.enumerated().map { "[\($0.offset + 1)] \($0.element.displayTitle) \($0.element.url)" }
        return "\n\n出处：\n" + lines.joined(separator: "\n")
    }

    private var plainText: String {
        PlainTextExporter.plainText(from: note.content) + sourcesText
    }

    private func startEditing() {
        draftText = note.content
        draftSources = note.sources
        showsPreview = false
        isEditing = true
    }

    private func finishEditing() {
        note.content = draftText
        note.sources = draftSources
        note.updatedAt = .now
        try? context.save()
        isEditing = false
    }

    private func export() {
        let markdown = "# \(note.title)\n\n" + plainText + "\n"
        do {
            shareItem = ShareItem(items: [try ExportFile.write(markdown, name: note.title, fallback: "资料", extension: "md")])
        } catch {
            errorMessage = "导出失败：\(error.localizedDescription)"
        }
    }
}

/// 写一个临时文件给分享菜单用，文件名用标题。
enum ExportFile {
    static func write(_ text: String, name: String, fallback: String, extension ext: String) throws -> URL {
        try write(Data(text.utf8), name: name, fallback: fallback, extension: ext)
    }

    static func write(_ data: Data, name: String, fallback: String, extension ext: String) throws -> URL {
        let safe = name
            .components(separatedBy: CharacterSet(charactersIn: "/\\:?*\"<>|\n"))
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespaces)
        let fileName = (safe.isEmpty ? fallback : String(safe.prefix(40))) + "." + ext
        let directory = FileManager.default.temporaryDirectory.appending(path: "export", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appending(path: fileName)
        try data.write(to: url, options: .atomic)
        return url
    }
}
