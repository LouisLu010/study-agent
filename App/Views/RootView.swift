import StudyKit
import SwiftData
import SwiftUI

struct RootView: View {
    @Environment(\.modelContext) private var context
    @Environment(GenerationCenter.self) private var generation
    @Environment(AppNavigation.self) private var navigation
    @Environment(CompilationCenter.self) private var compilations
    @Environment(\.scenePhase) private var scenePhase
    @AppStorage(AppSettingsKey.onboardingSeen) private var onboardingSeen = false

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
                case .review:
                    ReviewSessionView()
                case .bookmarks:
                    BookmarksView()
                case .stats:
                    StudyStatsView()
                case .notes:
                    ResearchNotesView()
                case .compilations:
                    CompilationsView()
                case nil:
                    OrbEmptyState(title: "没有选中的会话", message: "点右上角的按钮新建一个会话。")
                }
            }
        }
        .fullScreenCover(isPresented: $navigation.showsOnboarding) {
            OnboardingView()
        }
        .task {
            generation.recoverInterruptedMessages(in: context)
            compilations.recoverInterrupted(in: context)
            // 本机还没有服务商、也没跳过过引导时显示引导（见 GLOSSARY「引导」）。
            let providerCount = (try? context.fetchCount(FetchDescriptor<Provider>())) ?? 0
            if providerCount == 0 && !onboardingSeen {
                navigation.showsOnboarding = true
            }
        }
        .onChange(of: scenePhase) {
            // 回到前台或退到后台时重新排复习提醒，通知里的题数保持准确。
            if scenePhase != .inactive { ReviewReminder.reschedule(in: context) }
            // 回到前台：继续因为切到别的 App 被系统打断的汇编。
            if scenePhase == .active { compilations.resumeInterrupted(in: context) }
        }
    }
}
