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
    @Environment(ToastCenter.self) private var toasts

    var body: some View {
        @Bindable var navigation = navigation
        NavigationSplitView(preferredCompactColumn: $compactColumn) {
            ConversationListView(selection: $navigation.selection)
        } detail: {
            NavigationStack {
                switch navigation.selection {
                case .today:
                    TodayView()
                case .assistant:
                    StudyAssistantHomeView()
                case .canvases:
                    StudyCanvasesView()
                case .investigations:
                    InvestigationsView()
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
            generation.studyToasts = toasts
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
        // 离开一个什么都没写的会话时删掉它（第九版）。以前挂在聊天页的 onDisappear 上，
        // 但弹出相机这类全屏页面时聊天页也会触发 onDisappear，会把正在拍题的新会话删掉。
        .onChange(of: navigation.selection) { old, _ in
            if case let .conversation(conversation) = old { discardIfEmpty(conversation) }
            // 离开资料页后，"刚整理的"那一节就不再单独列出。
            if old == .notes { navigation.recentNoteID = nil }
        }
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

    /// 没有消息、没写会话提示词、也没换过人格的会话。写过或换过的留着，那是用户特意设置的。
    private func discardIfEmpty(_ conversation: Conversation) {
        guard conversation.modelContext != nil,
              !conversation.isDeleted,
              !toasts.isHidden(conversation),
              !generation.isGenerating(conversation),
              (conversation.messages ?? []).isEmpty,
              conversation.instructions.isEmpty,
              conversation.personaID.isEmpty
        else { return }
        context.delete(conversation)
        try? context.save()
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
