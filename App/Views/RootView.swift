import StudyKit
import SwiftData
import SwiftUI

struct RootView: View {
    @Environment(\.modelContext) private var context
    @Environment(GenerationCenter.self) private var generation
    @State private var selection: Conversation?

    var body: some View {
        NavigationSplitView {
            ConversationListView(selection: $selection)
        } detail: {
            if let conversation = selection {
                ChatView(conversation: conversation)
                    .id(conversation.id)
            } else {
                ContentUnavailableView(
                    "没有选中的会话",
                    systemImage: "bubble.left.and.bubble.right",
                    description: Text("点右上角的按钮新建一个会话。")
                )
            }
        }
        .task {
            generation.recoverInterruptedMessages(in: context)
        }
    }
}
