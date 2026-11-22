import StudyKit
import SwiftData
import SwiftUI

extension StudyCenter {
    static func bookmark(for messageID: UUID, in context: ModelContext) -> Bookmark? {
        let id: UUID? = messageID
        let descriptor = FetchDescriptor<Bookmark>(predicate: #Predicate { $0.sourceMessageID == id })
        return try? context.fetch(descriptor).first
    }

    /// 收藏一整条回答（独立副本），或者取消收藏。返回操作后是否处于收藏状态。
    @discardableResult
    static func toggleBookmark(_ message: Message, context: ModelContext) -> Bool {
        if let existing = bookmark(for: message.id, in: context) {
            context.delete(existing)
            try? context.save()
            return false
        }
        let conversation = message.conversation
        let bookmark = Bookmark(title: conversation?.title ?? "收藏", content: message.content)
        bookmark.componentStateJSON = message.componentStateJSON
        bookmark.modelName = conversation?.model?.name ?? ""
        bookmark.sourceConversationID = conversation?.id
        bookmark.sourceMessageID = message.id
        context.insert(bookmark)
        try? context.save()
        classify(bookmark, model: conversation?.model, context: context)
        return true
    }
}

struct BookmarksView: View {
    @Environment(\.modelContext) private var context
    @Query(sort: \Bookmark.createdAt, order: .reverse) private var bookmarks: [Bookmark]
    @State private var subject: Subject?
    @State private var searchText = ""

    private var filtered: [Bookmark] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        return bookmarks.filter { bookmark in
            if let subject, bookmark.subject != subject { return false }
            guard !query.isEmpty else { return true }
            return bookmark.title.localizedStandardContains(query)
                || bookmark.topic.localizedStandardContains(query)
                || bookmark.content.localizedStandardContains(query)
        }
    }

    private var subjects: [Subject] {
        let present = Set(bookmarks.compactMap(\.subject))
        return Subject.allCases.filter(present.contains)
    }

    var body: some View {
        List {
            if !subjects.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        SubjectChip(title: "全部科目", isSelected: subject == nil) { subject = nil }
                        ForEach(subjects) { item in
                            SubjectChip(title: item.rawValue, isSelected: subject == item) { subject = item }
                        }
                    }
                }
                .listRowSeparator(.hidden)
                .listRowBackground(Color.clear)
                .listRowInsets(EdgeInsets(top: Theme.Spacing.xs, leading: Theme.Spacing.l, bottom: Theme.Spacing.xs, trailing: Theme.Spacing.l))
            }
            ForEach(filtered) { bookmark in
                NavigationLink {
                    BookmarkDetailView(bookmark: bookmark)
                } label: {
                    LibraryRow(
                        title: bookmark.title,
                        subject: bookmark.subject?.rawValue ?? "分类中…",
                        summary: String(PlainTextExporter.plainText(from: bookmark.content).prefix(120)),
                        meta: [bookmark.topic, bookmark.createdAt.formatted(.dateTime.month().day())]
                            .filter { !$0.isEmpty }.joined(separator: " · ")
                    )
                }
            }
            .onDelete { offsets in
                offsets.map { filtered[$0] }.forEach(context.delete)
                try? context.save()
            }
        }
        .listStyle(.insetGrouped)
        .overlay {
            if bookmarks.isEmpty {
                OrbEmptyState(title: "还没有收藏", message: "点回答下方的书签按钮，就能把整条回答收藏到这里。")
            } else if filtered.isEmpty {
                ContentUnavailableView.search(text: searchText)
            }
        }
        .searchable(text: $searchText, prompt: "搜索收藏")
        .navigationTitle("收藏")
    }
}

struct BookmarkDetailView: View {
    @Bindable var bookmark: Bookmark

    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @Environment(GenerationCenter.self) private var generation
    @Environment(AppNavigation.self) private var navigation
    @State private var errorMessage: String?
    @State private var shareItem: ShareItem?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Picker("科目", selection: Binding(get: { bookmark.subject ?? .other }, set: { bookmark.subject = $0 })) {
                        ForEach(Subject.allCases) { Text($0.rawValue).tag($0) }
                    }
                    .labelsHidden()
                    TextField("知识点", text: $bookmark.topic)
                        .textFieldStyle(.roundedBorder)
                }
                RenderedContentView(
                    id: bookmark.id,
                    content: bookmark.content,
                    componentStateJSON: bookmark.componentStateJSON,
                    onComponentState: { key, state in
                        bookmark.componentStateJSON = ComponentStateStore.updating(bookmark.componentStateJSON, key: key, state: state)
                        try? context.save()
                    },
                    onAsk: { text in
                        do {
                            try StudyCenter.startConversation(
                                title: "提问：" + bookmark.title, prompt: text,
                                context: context, generation: generation, navigation: navigation
                            )
                        } catch {
                            errorMessage = error.localizedDescription
                        }
                    }
                )
                if !bookmark.modelName.isEmpty {
                    Text("来自 \(bookmark.modelName) · 收藏于 \(bookmark.createdAt.formatted(date: .abbreviated, time: .shortened))")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
            }
            .padding()
            .frame(maxWidth: 820)
            .frame(maxWidth: .infinity)
        }
        .navigationTitle(bookmark.title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Menu {
                    Button("复制", systemImage: "doc.on.doc") {
                        UIPasteboard.general.string = PlainTextExporter.plainText(from: bookmark.content)
                    }
                    if bookmark.sourceConversationID != nil {
                        Button("查看原会话", systemImage: "bubble.left.and.text.bubble.right") {
                            if !navigation.open(conversationID: bookmark.sourceConversationID, in: context) {
                                errorMessage = "原会话已经删除了。"
                            }
                        }
                    }
                    Button("取消收藏", systemImage: "bookmark.slash", role: .destructive) {
                        context.delete(bookmark)
                        try? context.save()
                        dismiss()
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
            }
        }
        .onDisappear { try? context.save() }
        .alert("提示", isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })) {
            Button("好", role: .cancel) {}
        } message: {
            Text(errorMessage ?? "")
        }
    }
}
