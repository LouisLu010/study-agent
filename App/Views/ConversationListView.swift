import StudyKit
import SwiftData
import SwiftUI

struct ConversationListView: View {
    @Binding var selection: Conversation?

    @Environment(\.modelContext) private var context
    @Environment(GenerationCenter.self) private var generation
    @Query(sort: \Conversation.updatedAt, order: .reverse) private var conversations: [Conversation]
    @Query private var models: [ChatModel]
    @State private var showSettings = false
    @State private var searchText = ""
    @State private var renaming: Conversation?
    @State private var renameText = ""

    private var filtered: [Conversation] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return conversations }
        return conversations.filter { $0.title.localizedStandardContains(query) }
    }

    var body: some View {
        List(selection: $selection) {
            ForEach(filtered) { conversation in
                NavigationLink(value: conversation) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(conversation.title)
                            .lineLimit(1)
                        Text(conversation.model?.name ?? "未选择模型")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
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
        .searchable(text: $searchText, prompt: "搜索会话标题")
        .overlay {
            if conversations.isEmpty {
                if models.isEmpty {
                    ContentUnavailableView {
                        Label("还没有模型", systemImage: "cpu")
                    } description: {
                        Text("先在设置里添加一个服务商和模型。")
                    } actions: {
                        Button("打开设置") { showSettings = true }
                    }
                } else {
                    ContentUnavailableView(
                        "还没有会话",
                        systemImage: "square.and.pencil",
                        description: Text("点右上角的按钮新建一个会话。")
                    )
                }
            } else if filtered.isEmpty {
                ContentUnavailableView.search(text: searchText)
            }
        }
        .navigationTitle("会话")
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Button("设置", systemImage: "gearshape") { showSettings = true }
            }
            ToolbarItem(placement: .topBarTrailing) {
                Button("新会话", systemImage: "square.and.pencil", action: newConversation)
            }
        }
        .sheet(isPresented: $showSettings) {
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

    private func newConversation() {
        let conversation = Conversation()
        context.insert(conversation)
        conversation.model = ModelLookup.defaultModel(in: context)
        try? context.save()
        selection = conversation
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

    private func delete(_ conversation: Conversation) {
        if selection == conversation {
            selection = nil
        }
        generation.stop(conversation)
        context.delete(conversation)
        try? context.save()
    }
}
