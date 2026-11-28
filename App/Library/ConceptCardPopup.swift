import StudyKit
import SwiftData
import SwiftUI

/// 点知识卡弹出的弹窗（第十版）。iPhone 上是底部半屏面板，iPad 上是贴着那张卡的浮窗（`.popover` 在窄屏上自动变成面板）。
/// 点关联的卡在同一个弹窗里换成那张卡，左上角"返回"一路退回去，弹窗不会叠很多层。
struct ConceptCardPopup: View {
    let startID: UUID
    /// "在关系图里看"。为 nil 时不显示（已经在关系图里了）。
    var onShowInMap: ((UUID) -> Void)?
    /// 弹窗里换了一张卡（点了关联的卡或返回）。关系图用它把图移到那个节点。
    var onCurrentChange: (UUID) -> Void = { _ in }

    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @Environment(AppNavigation.self) private var navigation
    @Environment(ToastCenter.self) private var toasts
    @Query(sort: \ConceptCard.updatedAt, order: .reverse) private var cards: [ConceptCard]
    @Query private var links: [ConceptLink]
    @Query private var notes: [ResearchNote]

    private enum Mode { case view, edit, addLink }

    @State private var stack: [UUID] = []
    @State private var mode = Mode.view
    @State private var detent = PresentationDetent.medium
    @State private var draftTitle = ""
    @State private var draftContent = ""
    @State private var draftExample = ""
    @State private var linkSearch = ""
    @State private var linkTarget: UUID?
    @State private var linkChoice = LinkChoice.prerequisite
    @State private var linkReason = ""
    @State private var linkError: String?
    @State private var errorMessage: String?
    @State private var originalNote: ResearchNote?

    private var currentID: UUID { stack.last ?? startID }
    private var current: ConceptCard? { cards.first { $0.id == currentID && !toasts.isHidden($0) } }

    var body: some View {
        VStack(spacing: 0) {
            header
            if let card = current {
                switch mode {
                case .view: viewer(card)
                case .edit: editor(card)
                case .addLink: linkPicker(card)
                }
            } else {
                ContentUnavailableView("这张知识卡已经删除了", systemImage: "rectangle.on.rectangle.slash")
            }
        }
        .frame(minWidth: 360, idealWidth: 440, minHeight: 380, idealHeight: 620)
        .accessibilityIdentifier("concept-card-popup")
        .presentationDetents([.medium, .large], selection: $detent)
        .presentationDragIndicator(.visible)
        .presentationCompactAdaptation(.sheet)
        .presentationBackground(Color(.systemBackground))
        .onAppear { if stack.isEmpty { stack = [startID] } }
        .sheet(item: $originalNote) { note in
            NavigationStack {
                ResearchNoteDetailView(note: note, showsCloseButton: true)
            }
        }
        .alert("提示", isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })) {
            Button("好", role: .cancel) {}
        } message: {
            Text(errorMessage ?? "")
        }
    }

    // MARK: - 顶栏

    private var header: some View {
        HStack {
            if mode != .view {
                Button("取消") { mode = .view }
            } else if stack.count > 1 {
                Button("返回", systemImage: "chevron.left") {
                    stack.removeLast()
                    onCurrentChange(currentID)
                }
            }
            Spacer()
            switch mode {
            case .view:
                Button("关闭", systemImage: "xmark.circle.fill") { dismiss() }
                    .labelStyle(.iconOnly)
                    .font(.title3)
                    .foregroundStyle(.secondary)
            case .edit:
                Button("保存", action: saveEdits)
                    .fontWeight(.semibold)
                    .disabled(draftTitle.trimmingCharacters(in: .whitespaces).isEmpty || draftContent.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            case .addLink:
                Button("添加", action: addLink)
                    .fontWeight(.semibold)
                    .disabled(linkTarget == nil)
            }
        }
        .padding(.horizontal, Theme.Spacing.l)
        .padding(.top, Theme.Spacing.m)
        .padding(.bottom, Theme.Spacing.xs)
    }

    // MARK: - 查看

    private func viewer(_ card: ConceptCard) -> some View {
        let neighbors = ConceptCardStore.neighbors(of: card, cards: cards.filter { !toasts.isHidden($0) }, links: links)
        return ScrollView {
            VStack(alignment: .leading, spacing: Theme.Spacing.m) {
                VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
                    Text(card.title)
                        .font(.title2.bold())
                    Text([card.subject?.rawValue ?? "", card.topic].filter { !$0.isEmpty }.joined(separator: " · "))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                RenderedContentView(id: card.id, content: Self.markdown(card))
                if !card.sources.isEmpty {
                    SourceListView(sources: card.sources, numbered: true)
                }

                if !neighbors.isEmpty {
                    VStack(alignment: .leading, spacing: Theme.Spacing.s) {
                        ForEach(ConceptCardStore.labelOrder, id: \.self) { label in
                            let group = neighbors.filter { $0.label == label }
                            if !group.isEmpty {
                                Text(label)
                                    .font(.caption.bold())
                                    .foregroundStyle(.secondary)
                                    .padding(.top, Theme.Spacing.xs)
                                ForEach(group) { neighbor in
                                    neighborRow(neighbor)
                                }
                            }
                        }
                    }
                }

                Button("添加关联", systemImage: "plus") {
                    linkSearch = ""
                    linkTarget = nil
                    linkReason = ""
                    linkError = nil
                    mode = .addLink
                    detent = .large
                }
                .buttonStyle(.bordered)

                actions(card)
            }
            .padding(.horizontal, Theme.Spacing.l)
            .padding(.bottom, Theme.Spacing.xl)
        }
    }

    private func neighborRow(_ neighbor: ConceptCardStore.Neighbor) -> some View {
        Button {
            stack.append(neighbor.card.id)
            onCurrentChange(neighbor.card.id)
        } label: {
            HStack(spacing: Theme.Spacing.m) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(neighbor.card.title)
                        .foregroundStyle(.primary)
                    if !neighbor.link.reason.isEmpty {
                        Text(neighbor.link.reason)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer(minLength: 0)
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.tertiary)
            }
            .padding(Theme.Spacing.m)
            .contentShape(Rectangle())
            .cardBackground()
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button("删除这条关联", systemImage: "trash", role: .destructive) {
                ConceptCardStore.remove(neighbor.link, context: context)
            }
        }
    }

    private func actions(_ card: ConceptCard) -> some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.s) {
            Divider()
            Button("编辑", systemImage: "pencil") {
                draftTitle = card.title
                draftContent = card.content
                draftExample = card.example
                mode = .edit
                detent = .large
            }
            if let note = ConceptCardStore.originalNote(for: card, in: notes), !toasts.isHidden(note) {
                Button("查看原资料", systemImage: "doc.text") { originalNote = note }
            }
            if card.sourceConversationID != nil {
                Button("回到原会话", systemImage: "bubble.left.and.text.bubble.right") {
                    if navigation.open(conversationID: card.sourceConversationID, in: context) {
                        dismiss()
                    } else {
                        errorMessage = "原会话已经删除了。"
                    }
                }
            }
            if let onShowInMap {
                Button("在关系图里看", systemImage: "point.3.connected.trianglepath.dotted") {
                    let id = card.id
                    dismiss()
                    onShowInMap(id)
                }
            }
            Button("删除", systemImage: "trash", role: .destructive) {
                toasts.delete([card], scope: .notes, message: "已删除知识卡") { [context] in
                    ConceptCardStore.delete(card, context: context)
                }
                dismiss()
            }
            if !card.modelName.isEmpty {
                Text("由 \(card.modelName) 整理 · \(card.updatedAt.formatted(date: .abbreviated, time: .omitted))")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .padding(.top, Theme.Spacing.xs)
            }
        }
        .buttonStyle(.borderless)
    }

    /// 弹窗和列表里显示的内容：核心内容，有例子时接一段"例"。
    static func markdown(_ card: ConceptCard) -> String {
        card.example.isEmpty ? card.content : card.content + "\n\n> **例**　" + card.example
    }

    // MARK: - 编辑

    private func editor(_ card: ConceptCard) -> some View {
        Form {
            Section("标题") {
                TextField("标题", text: $draftTitle)
            }
            Section("核心内容") {
                TextEditor(text: $draftContent)
                    .font(.system(.callout, design: .monospaced))
                    .frame(minHeight: 160)
            }
            Section("例子（可以不写）") {
                TextEditor(text: $draftExample)
                    .font(.system(.callout, design: .monospaced))
                    .frame(minHeight: 80)
            }
        }
    }

    private func saveEdits() {
        guard let card = current else { return }
        card.title = draftTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        card.content = draftContent.trimmingCharacters(in: .whitespacesAndNewlines)
        card.example = draftExample.trimmingCharacters(in: .whitespacesAndNewlines)
        card.updatedAt = .now
        try? context.save()
        mode = .view
    }

    // MARK: - 添加关联

    /// 从这张卡看过去的五种说法，对应三种关联和方向。
    private enum LinkChoice: String, CaseIterable, Identifiable {
        case prerequisite, followUp, contrast, application, basis
        var id: String { rawValue }

        var title: String {
            switch self {
            case .prerequisite: "前置：先懂它才能懂这张"
            case .followUp: "后续：先懂这张才能懂它"
            case .contrast: "对比：两个容易混淆"
            case .application: "应用：它是这张的用法"
            case .basis: "依据：这张是它的用法"
            }
        }

        var kind: LinkKind {
            switch self {
            case .prerequisite, .followUp: .prerequisite
            case .contrast: .contrast
            case .application, .basis: .application
            }
        }

        /// 这张卡在关联的 from 那一头。
        var currentIsFrom: Bool { self == .followUp || self == .application || self == .contrast }
    }

    private func linkPicker(_ card: ConceptCard) -> some View {
        let linked = Set(ConceptCardStore.neighbors(of: card, cards: cards, links: links).map(\.card.id))
        let query = linkSearch.trimmingCharacters(in: .whitespacesAndNewlines)
        let options = cards.filter { other in
            other.id != card.id && !toasts.isHidden(other) && (other.subject ?? .other) == (card.subject ?? .other)
                && !linked.contains(other.id)
                && (query.isEmpty || other.title.localizedStandardContains(query) || other.topic.localizedStandardContains(query))
        }
        return Form {
            Section("关系") {
                Picker("关系", selection: $linkChoice) {
                    ForEach(LinkChoice.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.inline)
                .labelsHidden()
                TextField("理由（可以不写）", text: $linkReason)
            }
            Section {
                TextField("搜索\(card.subject?.rawValue ?? "")的知识卡", text: $linkSearch)
                if options.isEmpty {
                    Text("没有可以关联的知识卡").foregroundStyle(.secondary)
                }
                ForEach(options) { other in
                    Button {
                        linkTarget = other.id
                    } label: {
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(other.title).foregroundStyle(.primary)
                                Text(other.topic).font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            if linkTarget == other.id {
                                Image(systemName: "checkmark").foregroundStyle(.tint)
                            }
                        }
                    }
                }
            } footer: {
                if let linkError { Text(linkError).foregroundStyle(.red) }
            }
        }
    }

    private func addLink() {
        guard let card = current, let other = cards.first(where: { $0.id == linkTarget }) else { return }
        let (from, to) = linkChoice.currentIsFrom ? (card, other) : (other, card)
        if let error = ConceptCardStore.addLink(from: from, to: to, kind: linkChoice.kind, reason: linkReason, context: context) {
            linkError = error
        } else {
            mode = .view
        }
    }
}

extension View {
    /// 仅淡化未选中的卡片；加在卡片内容上，避免影响选中的卡片和弹窗。
    func popupBackdrop(_ active: Bool) -> some View {
        modifier(PopupBackdrop(active: active))
    }
}

private struct PopupBackdrop: ViewModifier {
    let active: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        content
            .opacity(active ? 0.45 : 1)
            .animation(reduceMotion ? nil : .smooth(duration: 0.25), value: active)
    }
}
