import StudyKit
import SwiftData
import SwiftUI

/// 资料页（第十版）：知识卡按科目、知识点分组；以前的整篇资料放在最后。点知识卡弹出弹窗，不切换页面。
struct ResearchNotesView: View {
    @Environment(\.modelContext) private var context
    @Environment(ToastCenter.self) private var toasts
    @Environment(AppNavigation.self) private var navigation
    @Query(sort: \ResearchNote.updatedAt, order: .reverse) private var notes: [ResearchNote]
    @Query(sort: \ConceptCard.updatedAt, order: .reverse) private var cards: [ConceptCard]
    @Query private var links: [ConceptLink]
    @State private var subject: Subject?
    @State private var searchText = ""
    /// 弹窗挂在哪一行上。同一张卡可能同时出现在"刚整理的"和它的知识点下面，所以带上是哪一节。
    @State private var popup: CardAnchor?
    @State private var mode = Mode.cards
    @State private var mapSubject: Subject?
    @State private var mapFocus: UUID?

    enum Mode: String, CaseIterable, Identifiable {
        case cards = "知识卡"
        case map = "关系图"
        var id: String { rawValue }
    }

    struct CardAnchor: Equatable {
        let cardID: UUID
        let section: String
    }

    private var query: String { searchText.trimmingCharacters(in: .whitespacesAndNewlines) }

    private var visibleCards: [ConceptCard] {
        cards.filter { card in
            if toasts.isHidden(card) { return false }
            if let subject, (card.subject ?? .other) != subject { return false }
            guard !query.isEmpty else { return true }
            return card.title.localizedStandardContains(query) || card.topic.localizedStandardContains(query)
                || card.content.localizedStandardContains(query) || card.example.localizedStandardContains(query)
        }
    }

    /// 以前的整篇资料（还没拆成知识卡的）。
    private var oldNotes: [ResearchNote] {
        notes.filter { note in
            guard !note.isCardBased, !toasts.isHidden(note) else { return false }
            if let subject, (note.subject ?? .other) != subject { return false }
            guard !query.isEmpty else { return true }
            return note.title.localizedStandardContains(query) || note.topic.localizedStandardContains(query)
                || note.content.localizedStandardContains(query)
        }
    }

    private var recentCards: [ConceptCard] {
        guard let id = navigation.recentNoteID, query.isEmpty else { return [] }
        return visibleCards.filter { $0.noteID == id }.sorted { $0.createdAt < $1.createdAt }
    }

    /// 科目 → 知识点 → 知识卡。
    private var groups: [(subject: Subject, topics: [(topic: String, cards: [ConceptCard])])] {
        let visible = visibleCards
        return Subject.allCases.compactMap { subject in
            let inSubject = visible.filter { ($0.subject ?? .other) == subject }
            guard !inSubject.isEmpty else { return nil }
            let topics = Dictionary(grouping: inSubject) { $0.topic.isEmpty ? "未分类" : $0.topic }
                .map { (topic: $0.key, cards: $0.value.sorted { $0.createdAt < $1.createdAt }) }
                .sorted { $0.topic.localizedStandardCompare($1.topic) == .orderedAscending }
            return (subject, topics)
        }
    }

    private var subjects: [Subject] {
        let present = Set(cards.map { $0.subject ?? .other } + notes.filter { !$0.isCardBased }.map { $0.subject ?? .other })
        return Subject.allCases.filter(present.contains)
    }

    private var isEmpty: Bool {
        cards.allSatisfy { toasts.isHidden($0) } && notes.filter { !$0.isCardBased }.allSatisfy { toasts.isHidden($0) }
    }

    var body: some View {
        Group {
            switch mode {
            case .cards: cardList
            case .map: ConceptMapView(subject: $mapSubject, focusRequest: $mapFocus).toastBar(.notes)
            }
        }
        .navigationTitle("资料")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .principal) {
                Picker("显示", selection: $mode) {
                    ForEach(Mode.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .frame(width: 200)
            }
        }
        .onAppear(perform: takeMapFocus)
        .onChange(of: navigation.mapFocusCardID) { takeMapFocus() }
        .onChange(of: subject) { if let subject { mapSubject = subject } }
    }

    /// 弹窗里点了"在关系图里看"：切到关系图，聚焦那张卡。
    private func takeMapFocus() {
        guard let id = navigation.mapFocusCardID else { return }
        navigation.mapFocusCardID = nil
        mapFocus = id
        mode = .map
    }

    /// 知识卡排成卡片网格（第十版 Beta 2）：每张卡片显示标题和内容预览，点开弹出弹窗。
    private var cardList: some View {
        let colors = ConceptCardStore.topicColors(cards.map(\.topic))
        let linkCounts = linkCountByCard
        return ScrollView {
            LazyVStack(alignment: .leading, spacing: Theme.Spacing.l, pinnedViews: []) {
                if subjects.count > 1 {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 8) {
                            SubjectChip(title: "全部科目", isSelected: subject == nil) { subject = nil }
                            ForEach(subjects) { item in
                                SubjectChip(title: item.rawValue, isSelected: subject == item) { subject = item }
                            }
                        }
                    }
                }
                if !recentCards.isEmpty {
                    sectionHeader("刚整理的 \(recentCards.count) 张")
                    grid(recentCards, section: "recent", colors: colors, linkCounts: linkCounts)
                }
                ForEach(groups, id: \.subject) { group in
                    sectionHeader(group.subject.rawValue)
                    ForEach(group.topics, id: \.topic) { topic in
                        HStack(spacing: Theme.Spacing.s) {
                            Circle().fill(colors[topic.topic] ?? .accentColor).frame(width: 8, height: 8)
                            Text(topic.topic).font(.subheadline.weight(.semibold)).foregroundStyle(.secondary)
                            Text("\(topic.cards.count)").font(.caption).foregroundStyle(.tertiary)
                        }
                        grid(topic.cards, section: group.subject.rawValue, colors: colors, linkCounts: linkCounts)
                    }
                }
                if !oldNotes.isEmpty {
                    sectionHeader("以前的资料")
                    VStack(spacing: 0) {
                        ForEach(oldNotes) { note in
                            NavigationLink {
                                ResearchNoteDetailView(note: note)
                            } label: {
                                LibraryRow(
                                    title: PlainTextExporter.previewText(from: note.title),
                                    subject: note.subject?.rawValue,
                                    summary: String(PlainTextExporter.previewText(from: note.content).prefix(120)),
                                    meta: note.updatedAt.formatted(.dateTime.month().day())
                                ) {
                                    Image(systemName: "chevron.right").font(.caption.weight(.semibold)).foregroundStyle(.tertiary)
                                }
                                .padding(.horizontal, Theme.Spacing.l)
                                .padding(.vertical, Theme.Spacing.s)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .contextMenu {
                                Button("删除", systemImage: "trash", role: .destructive) {
                                    toasts.delete([note], scope: .notes) { [context] in
                                        context.delete(note)
                                        try? context.save()
                                    }
                                }
                            }
                            if note.id != oldNotes.last?.id { Divider().padding(.leading, Theme.Spacing.l) }
                        }
                    }
                    .groupedCardBackground()
                }
            }
            .padding(Theme.Spacing.l)
            .frame(maxWidth: 1100)
            .frame(maxWidth: .infinity)
        }
        .groupedPageBackground()
        .popupBackdrop(popup != nil)
        .toastBar(.notes)
        .overlay {
            if isEmpty {
                OrbEmptyState(
                    title: "还没有资料",
                    message: "在会话标题菜单或回答下方点\"整理成资料\"。"
                )
            } else if visibleCards.isEmpty && oldNotes.isEmpty {
                ContentUnavailableView.search(text: searchText)
            }
        }
        .searchable(text: $searchText, prompt: "搜索知识卡")
    }

    /// 每张卡有几条关联（不含用户删掉的）。
    private var linkCountByCard: [UUID: Int] {
        var count: [UUID: Int] = [:]
        for link in links where !link.dismissed {
            if let id = link.fromID { count[id, default: 0] += 1 }
            if let id = link.toID { count[id, default: 0] += 1 }
        }
        return count
    }

    private func sectionHeader(_ title: String) -> some View {
        Text(title)
            .font(.title3.bold())
            .padding(.top, Theme.Spacing.s)
    }

    private func grid(_ items: [ConceptCard], section: String, colors: [String: Color], linkCounts: [UUID: Int]) -> some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 160, maximum: 280), spacing: Theme.Spacing.m)], spacing: Theme.Spacing.m) {
            ForEach(items) { card in
                cardTile(card, section: section, color: colors[card.topic] ?? .accentColor, links: linkCounts[card.id] ?? 0)
            }
        }
    }

    private func cardTile(_ card: ConceptCard, section: String, color: Color, links: Int) -> some View {
        let anchor = CardAnchor(cardID: card.id, section: section)
        return Button {
            popup = anchor
        } label: {
            ConceptCardTile(card: card, color: color, links: links)
        }
        .buttonStyle(.plain)
        .popover(isPresented: Binding(get: { popup == anchor }, set: { if !$0, popup == anchor { popup = nil } })) {
            ConceptCardPopup(startID: card.id, onShowInMap: showInMap)
        }
        .contextMenu {
            Button("删除", systemImage: "trash", role: .destructive) {
                toasts.delete([card], scope: .notes, message: "已删除知识卡") { [context] in
                    ConceptCardStore.delete(card, context: context)
                }
            }
        } preview: {
            ConceptCardTile(card: card, color: color, links: links, expanded: true)
                .frame(width: 300)
        }
    }

    private func showInMap(_ id: UUID) {
        popup = nil
        navigation.mapFocusCardID = id
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
    @State private var splitRequest: NoteDraftRequest?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                // 第十版：以前的整篇资料可以拆成知识卡，点了才调一次模型。
                if !note.isCardBased && !isEditing {
                    Button("拆成知识卡", systemImage: "rectangle.split.2x2", action: split)
                        .buttonStyle(.borderedProminent)
                }
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
                            .padding(Theme.Spacing.s)
                            .cardBackground()
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
                        if !note.isCardBased {
                            Button("拆成知识卡", systemImage: "rectangle.split.2x2", action: split)
                        }
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
        .sheet(item: $splitRequest) { request in
            NoteDraftSheet(request: request)
        }
        // 拆好以后这份资料由知识卡组成，回到资料页看那些卡。
        .onChange(of: note.isCardBased) { if note.isCardBased { dismiss() } }
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

    private func split() {
        guard let model = ModelLookup.defaultModel(in: context) else {
            errorMessage = GenerationError.noModel.localizedDescription
            return
        }
        splitRequest = .note(note, model: model)
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

/// 资料页上的一张知识卡（第十版 Beta 2）：顶上一条知识点颜色，标题，几行内容预览，底部是例子和关联数。
/// `expanded` 是长按时的大预览：内容多显示几行，带上例子。
struct ConceptCardTile: View {
    let card: ConceptCard
    let color: Color
    let links: Int
    var expanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.s) {
            Capsule()
                .fill(color)
                .frame(width: 28, height: 4)
            Text(card.title)
                .font(.headline)
                .foregroundStyle(.primary)
                .lineLimit(2)
                .multilineTextAlignment(.leading)
            Text(PlainTextExporter.previewText(from: card.content))
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .lineLimit(expanded ? 10 : 4)
                .multilineTextAlignment(.leading)
            if expanded && !card.example.isEmpty {
                Text("例　" + PlainTextExporter.previewText(from: card.example))
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .padding(Theme.Spacing.s)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(color.opacity(0.1), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            }
            Spacer(minLength: 0)
            HStack(spacing: Theme.Spacing.s) {
                if !card.example.isEmpty {
                    Label("有例子", systemImage: "lightbulb")
                }
                if links > 0 {
                    Label("\(links)", systemImage: "point.3.connected.trianglepath.dotted")
                }
                Spacer(minLength: 0)
                if !card.sources.isEmpty {
                    Label("\(card.sources.count)", systemImage: "link")
                }
            }
            .font(.caption2)
            .foregroundStyle(.tertiary)
            .labelStyle(.titleAndIcon)
        }
        .padding(Theme.Spacing.m)
        .frame(maxWidth: .infinity, minHeight: expanded ? nil : 170, alignment: .topLeading)
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(color.opacity(0.25), lineWidth: 1)
        }
        .contentShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
    }
}
