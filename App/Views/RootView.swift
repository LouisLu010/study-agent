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
    /// iPhone 上分栏合并成一栏：启动时直接显示"今天"，按返回回到侧栏。
    @State private var compactColumn = NavigationSplitViewColumn.detail
    @State private var quickActions = QuickActionInbox.shared

    var body: some View {
        @Bindable var navigation = navigation
        NavigationSplitView(preferredCompactColumn: $compactColumn) {
            ConversationListView(selection: $navigation.selection)
        } detail: {
            NavigationStack {
                switch navigation.selection {
                case .today:
                    TodayView()
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
                    TodayView()
                }
            }
        }
        .fullScreenCover(isPresented: $navigation.showsOnboarding) {
            OnboardingView()
        }
        .task {
            generation.recoverInterruptedMessages(in: context)
            compilations.recoverInterrupted(in: context)
            compilations.makePendingPDFs(in: context)
            // 本机还没有服务商、也没跳过过引导时显示引导（见 GLOSSARY「引导」）。
            let providerCount = (try? context.fetchCount(FetchDescriptor<Provider>())) ?? 0
            if providerCount == 0 && !onboardingSeen {
                navigation.showsOnboarding = true
            }
            // 没在运行时从快捷菜单打开：选择已经在收件箱里了。
            handleQuickAction()
            QuickAction.updateShortcutItems(in: context)
        }
        .onChange(of: quickActions.pending) { handleQuickAction() }
        .onChange(of: scenePhase) {
            // 回到前台或退到后台时重新排复习提醒，通知里的题数保持准确。
            if scenePhase != .inactive { ReviewReminder.reschedule(in: context) }
            // 退到后台时更新快捷菜单：有没有到期的错题决定放不放"开始复习"。
            if scenePhase == .background { QuickAction.updateShortcutItems(in: context) }
            // 回到前台：继续因为切到别的 App 被系统打断的汇编。
            if scenePhase == .active {
                compilations.resumeInterrupted(in: context)
                // 整理完时 App 在后台，PDF 没能生成：现在生成。
                compilations.makePendingPDFs(in: context)
            }
        }
    }

    /// 处理长按图标的快捷菜单（第九版）。引导还没走完时不处理。
    private func handleQuickAction() {
        guard let action = quickActions.pending else { return }
        quickActions.pending = nil
        guard !navigation.showsOnboarding else { return }
        switch action {
        case .newChat, .snapQuestion:
            guard let model = ModelLookup.defaultModel(in: context) else {
                navigation.selection = .today
                break
            }
            let conversation = Conversation()
            context.insert(conversation)
            conversation.model = model
            try? context.save()
            if action == .snapQuestion && model.supportsImages {
                navigation.cameraConversationID = conversation.id
            }
            navigation.selection = .conversation(conversation)
        case .review:
            navigation.selection = .review
        }
        compactColumn = .detail
    }
}
