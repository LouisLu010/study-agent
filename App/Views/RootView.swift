import StudyKit
import SwiftData
import SwiftUI

struct RootView: View {
    @Environment(\.modelContext) private var context
    @Environment(GenerationCenter.self) private var generation
    @Environment(AppNavigation.self) private var navigation
    @Environment(\.scenePhase) private var scenePhase

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
                    BookmarksView()
                case .stats:
                    StudyStatsView()
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
        .onChange(of: scenePhase) {
            // 回到前台或退到后台时重新排复习提醒，通知里的题数保持准确。
            if scenePhase != .inactive { ReviewReminder.reschedule(in: context) }
        }
    }
}
