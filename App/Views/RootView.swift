import StudyKit
import SwiftData
import SwiftUI

struct RootView: View {
    @Environment(\.modelContext) private var context
    @Environment(GenerationCenter.self) private var generation
    @Environment(AppNavigation.self) private var navigation

    var body: some View {
        @Bindable var navigation = navigation
        NavigationSplitView {
            ConversationListView(selection: $navigation.selection)
        } detail: {
            NavigationStack {
                switch navigation.selection {
                case let .conversation(conversation):
                    ChatView(conversation: conversation)
                        .id(conversation.id)
                case .mistakes:
                    MistakeBookView()
                case .bookmarks:
                    BookmarksPlaceholder()
                case .stats:
                    BookmarksPlaceholder()
                case nil:
                    ContentUnavailableView(
                        "没有选中的会话",
                        systemImage: "bubble.left.and.bubble.right",
                        description: Text("点右上角的按钮新建一个会话。")
                    )
                }
            }
        }
        .task {
            generation.recoverInterruptedMessages(in: context)
        }
    }
}

/// 收藏和学习记录在后续阶段实现。
private struct BookmarksPlaceholder: View {
    var body: some View {
        ContentUnavailableView("即将推出", systemImage: "hammer")
    }
}
