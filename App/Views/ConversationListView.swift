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

    var body: some View {
        List(selection: $selection) {
            ForEach(conversations) { conversation in
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
            }
            .onDelete(perform: delete)
        }
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
    }

    private func newConversation() {
        let conversation = Conversation()
        context.insert(conversation)
        conversation.model = ModelLookup.defaultModel(in: context)
        try? context.save()
        selection = conversation
    }

    private func delete(at offsets: IndexSet) {
        for index in offsets {
            let conversation = conversations[index]
            if selection == conversation {
                selection = nil
            }
            generation.stop(conversation)
            context.delete(conversation)
        }
        try? context.save()
    }
}
