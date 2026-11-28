import StudyKit
import SwiftData
import SwiftUI

struct ConversationListView: View {
    @Binding var selection: SidebarItem?

    @Environment(\.modelContext) private var context
    @Environment(GenerationCenter.self) private var generation
    @Environment(AppNavigation.self) private var navigation
    @Environment(ToastCenter.self) private var toasts
    @Query(sort: \Conversation.updatedAt, order: .reverse) private var conversations: [Conversation]
    @Query private var models: [ChatModel]
    @Query(filter: #Predicate<Mistake> { $0.masteredAt == nil }) private var activeMistakes: [Mistake]
    @State private var showSettings = false
    @State private var searchText = ""
    @State private var renaming: Conversation?
    @State private var renameText = ""

    private var filtered: [Conversation] {
        let visible = conversations.filter { !toasts.isHidden($0) }
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return visible }
        return visible.filter { $0.title.localizedStandardContains(query) }
    }

    var body: some View {
        List(selection: $selection) {
            if searchText.isEmpty {
                Section {
                    entry("今天", systemImage: "sun.max", item: .today)
                    entry("学习助手", systemImage: "sparkles", item: .assistant)
                }
                Section("学习") {
                    entry("学习画布", systemImage: "rectangle.3.group", item: .canvases)
                    entry("学习探索", systemImage: "lightbulb", item: .investigations)
                    entry("错题本", systemImage: "exclamationmark.bubble", item: .mistakes)
                    entry("复习", systemImage: "arrow.counterclockwise.circle", item: .review)
                        .badge(dueCount)
                    entry("收藏", systemImage: "bookmark", item: .bookmarks)
                    entry("学习记录", systemImage: "chart.bar", item: .stats)
                }
                Section("资料库") {
                    entry("资料", systemImage: "doc.text.magnifyingglass", item: .notes)
                    entry("汇编", systemImage: "books.vertical", item: .compilations)
                }
            }
            Section(searchText.isEmpty ? "会话" : "") {
            ForEach(filtered) { conversation in
                NavigationLink(value: SidebarItem.conversation(conversation)) {
                    HStack(spacing: Theme.Spacing.s) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(conversation.title)
                                .fontWeight(.medium)
                                .lineLimit(1)
                            Text((conversation.isStudyAssistant ? "学习助手 · " : "") + (conversation.model?.name ?? "未选择模型") + " · " + conversation.updatedAt.formatted(.relative(presentation: .named)))
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                        // 这个会话正在生成（可能在后台）。
                        if generation.isGenerating(conversation) {
                            Spacer(minLength: 0)
                            ActivityOrb(activity: .working, size: 16)
                        }
                    }
                }
                .contextMenu {
                    Button("重命名", systemImage: "pencil") { startRenaming(conversation) }
                    Button("删除", systemImage: "trash", role: .destructive) { delete(conversation) }
                }
                .swipeActions(edge: .trailing) {
                    Button("删除", systemImage: "trash", role: .destructive) { delete(conversation) }
                    Button("重命名", systemImage: "pencil") { startRenaming(conversation) }
                        .tint(.orange)
                }
            }
            }
        }
        // 第八版：浅灰底加白色圆角卡片，深色模式是黑底加深灰卡片。
        .listStyle(.insetGrouped)
        .searchable(text: $searchText, prompt: "搜索会话标题")
        .overlay {
            if conversations.isEmpty {
                if models.isEmpty {
                    OrbEmptyState(title: "还没有模型") {
                        VStack(spacing: Theme.Spacing.s) {
                            Button("开始设置") { navigation.showsOnboarding = true }
                                .buttonStyle(.borderedProminent)
                            Button("打开设置") { showSettings = true }
                        }
                    }
                }
                // 有模型但还没有会话时不盖住列表，顶部的错题本等入口仍然可以点。
            } else if filtered.isEmpty && !searchText.isEmpty {
                ContentUnavailableView.search(text: searchText)
            }
        }
        .toastBar(.conversations)
        .navigationTitle("格物")
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Button("设置", systemImage: "gearshape") { showSettings = true }
            }
            ToolbarItem(placement: .topBarTrailing) {
                Button("新会话", systemImage: "square.and.pencil", action: newConversation)
            }
        }
        .sheet(isPresented: $showSettings, onDismiss: {
            // 在设置里点了"重新查看引导"：设置完全关掉后再显示引导。
            if navigation.onboardingAfterSettings {
                navigation.onboardingAfterSettings = false
                navigation.showsOnboarding = true
            }
        }) {
            SettingsView()
        }
        .alert(
            "重命名会话",
            isPresented: Binding(
                get: { renaming != nil },
                set: { if !$0 { renaming = nil } }
            )
        ) {
            TextField("标题", text: $renameText)
            Button("取消", role: .cancel) {}
            Button("保存", action: finishRenaming)
        }
    }

    /// 侧栏顶部的入口，图标用主题色。
    private func entry(_ title: String, systemImage: String, item: SidebarItem) -> some View {
        NavigationLink(value: item) {
            Label {
                Text(title)
            } icon: {
                Image(systemName: systemImage)
                    .foregroundStyle(.tint)
            }
        }
    }

    /// 今天到期的错题数。
    private var dueCount: Int {
        activeMistakes.filter { ReviewSchedule.isDue($0) }.count
    }

    private func newConversation() {
        let conversation = Conversation()
        context.insert(conversation)
        conversation.model = ModelLookup.defaultModel(in: context)
        try? context.save()
        selection = .conversation(conversation)
    }

    private func startRenaming(_ conversation: Conversation) {
        renameText = conversation.title
        renaming = conversation
    }

    private func finishRenaming() {
        guard let conversation = renaming else { return }
        let title = renameText.trimmingCharacters(in: .whitespacesAndNewlines)
        if !title.isEmpty {
            conversation.title = title
            conversation.titleIsAutomatic = false
            try? context.save()
        }
        renaming = nil
    }

    /// 删除可以撤销（第九版）：先藏起来，5 秒后才真正删。正在生成的回答立刻停掉。
    private func delete(_ conversation: Conversation) {
        if selection == .conversation(conversation) {
            selection = .today
        }
        generation.stop(conversation)
        toasts.delete([conversation], scope: .conversations) { [context] in
            context.delete(conversation)
            try? context.save()
        }
    }
}
