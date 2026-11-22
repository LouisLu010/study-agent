import StudyKit
import SwiftData
import SwiftUI

/// 今天（见 GLOSSARY「今天」）：打开 App 默认看到的页面。
/// 上面是直接提问的输入框，下面是今天要复习的题、连续学习天数和最近 7 天答题数、继续上次的会话。
/// 没有错题时不显示复习卡片，没有答题记录时不显示学习卡片，两样都没有时显示空会话的示例问题。
struct TodayView: View {
    @Environment(\.modelContext) private var context
    @Environment(GenerationCenter.self) private var generation
    @Environment(AppNavigation.self) private var navigation
    @Query(filter: #Predicate<Mistake> { $0.masteredAt == nil }) private var activeMistakes: [Mistake]
    @Query private var events: [StudyEvent]
    @Query(sort: \Conversation.updatedAt, order: .reverse) private var conversations: [Conversation]
    @Query private var models: [ChatModel]
    @AppStorage(AppSettingsKey.defaultModelID) private var defaultModelID = ""

    @State private var draft = ""
    @State private var draftImages: [PendingImage] = []
    @State private var webSearchEnabled = false
    /// 这次提问用的模型，默认是默认模型，可以在输入框里换。
    @State private var model: ChatModel?
    @State private var errorMessage: String?
    @State private var examples = ExampleQuestions.random(4)

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Spacing.l) {
                Text(Date.now.formatted(.dateTime.month().day().weekday(.wide)))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)

                if models.isEmpty {
                    setupCard
                } else {
                    composer
                }

                if !activeMistakes.isEmpty {
                    reviewCard
                }
                if !events.isEmpty {
                    studyCard
                }
                if let last = lastConversation {
                    continueCard(last)
                }
                if activeMistakes.isEmpty && events.isEmpty && !models.isEmpty {
                    exampleList
                }
            }
            .padding(Theme.Spacing.l)
            .frame(maxWidth: 720)
            .frame(maxWidth: .infinity)
        }
        .scrollDismissesKeyboard(.interactively)
        .groupedPageBackground()
        .navigationTitle("今天")
        .task { if model == nil { model = ModelLookup.defaultModel(in: context) } }
        .onChange(of: defaultModelID) { model = ModelLookup.defaultModel(in: context) }
        .onChange(of: models.count) {
            if model == nil || model?.modelContext == nil { model = ModelLookup.defaultModel(in: context) }
        }
        .alert("提示", isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })) {
            Button("好", role: .cancel) {}
        } message: {
            Text(errorMessage ?? "")
        }
    }

    // MARK: - 提问

    private var composer: some View {
        ComposerView(
            text: $draft,
            images: $draftImages,
            imagesAllowed: model?.supportsImages ?? false,
            isGenerating: false,
            canSend: canSend,
            onSend: send,
            onStop: {},
            onImagesNotAllowed: { errorMessage = GenerationError.modelDoesNotSupportImages.localizedDescription },
            webSearchEnabled: $webSearchEnabled,
            webSearchAllowed: model?.supportsWebSearch ?? false,
            onWebSearchNotAllowed: {
                errorMessage = "当前模型不支持联网搜索。请切换到支持的模型，或在设置里为这个模型打开\"支持联网搜索\"。"
            },
            model: $model,
            placement: .inline
        )
    }

    private var trimmedDraft: String {
        draft.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var canSend: Bool {
        (!trimmedDraft.isEmpty || !draftImages.isEmpty) && model != nil
    }

    /// 新建一个会话发出去，然后跳到这个会话。
    private func send() {
        guard canSend, let model else { return }
        let conversation = Conversation()
        context.insert(conversation)
        conversation.model = model
        conversation.webSearchEnabled = webSearchEnabled && model.supportsWebSearch
        do {
            try context.save()
            try generation.send(trimmedDraft, images: draftImages.map(\.data), in: conversation, context: context)
        } catch {
            context.delete(conversation)
            try? context.save()
            errorMessage = error.localizedDescription
            return
        }
        draft = ""
        draftImages = []
        navigation.selection = .conversation(conversation)
    }

    private var setupCard: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.m) {
            Label("还没有模型", systemImage: "sparkles")
                .font(.headline)
            Text("先连上一个服务商，就能在这里直接提问。")
                .font(.callout)
                .foregroundStyle(.secondary)
            Button("开始设置") { navigation.showsOnboarding = true }
                .buttonStyle(.borderedProminent)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(Theme.Spacing.l)
        .groupedCardBackground()
    }

    // MARK: - 复习

    private var dueCount: Int {
        activeMistakes.filter { ReviewSchedule.isDue($0) }.count
    }

    private var reviewCard: some View {
        let due = dueCount
        let next = activeMistakes.map(\.dueAt).min()
        return VStack(alignment: .leading, spacing: Theme.Spacing.m) {
            cardTitle("复习", systemImage: "arrow.counterclockwise.circle")
            if due > 0 {
                HStack(alignment: .firstTextBaseline, spacing: Theme.Spacing.xs) {
                    Text("\(due)")
                        .font(.largeTitle.bold())
                        .monospacedDigit()
                    Text("道题今天要复习")
                        .foregroundStyle(.secondary)
                }
                Button {
                    navigation.selection = .review
                } label: {
                    Label("开始复习", systemImage: "play.fill")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .buttonBorderShape(.capsule)
                .controlSize(.large)
            } else {
                Text(next.map { "今天没有要复习的题，下一次在 \($0.formatted(.dateTime.month().day()))。" } ?? "今天没有要复习的题。")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(Theme.Spacing.l)
        .groupedCardBackground()
    }

    // MARK: - 学习

    private var studyCard: some View {
        let streak = StudyStats.streak(events.map(\.date))
        let week = StudyStats.daily(events, days: 7)
        let answered = week.reduce(0) { $0 + $1.answered }
        return VStack(alignment: .leading, spacing: Theme.Spacing.m) {
            cardTitle("学习", systemImage: "flame")
            HStack(alignment: .bottom, spacing: Theme.Spacing.xl) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("\(streak)")
                        .font(.largeTitle.bold())
                        .monospacedDigit()
                    Text("连续学习天数")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text("\(answered)")
                        .font(.largeTitle.bold())
                        .monospacedDigit()
                    Text("最近 7 天答题")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
                WeekBars(days: week)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(Theme.Spacing.l)
        .groupedCardBackground()
        .accessibilityElement(children: .combine)
    }

    // MARK: - 继续上次的会话

    /// 最近更新、而且有消息的会话。
    private var lastConversation: Conversation? {
        conversations.first { !($0.messages ?? []).isEmpty }
    }

    private func continueCard(_ conversation: Conversation) -> some View {
        Button {
            navigation.selection = .conversation(conversation)
        } label: {
            HStack(spacing: Theme.Spacing.m) {
                Image(systemName: "bubble.left.and.text.bubble.right")
                    .font(.title3)
                    .foregroundStyle(.tint)
                    .frame(width: 32)
                VStack(alignment: .leading, spacing: 2) {
                    Text("继续上次的会话")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text(conversation.title)
                        .fontWeight(.medium)
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                    Text(conversation.updatedAt.formatted(.relative(presentation: .named)))
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
                Spacer(minLength: 0)
                if generation.isGenerating(conversation) {
                    ActivityOrb(activity: .working, size: 16)
                }
                Image(systemName: "chevron.right")
                    .font(.caption.bold())
                    .foregroundStyle(.tertiary)
            }
            .padding(Theme.Spacing.l)
            .groupedCardBackground()
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    // MARK: - 示例问题

    private var exampleList: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.s) {
            Text("可以这样问")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.secondary)
            ForEach(examples) { example in
                Button {
                    draft = example.text
                } label: {
                    HStack(spacing: Theme.Spacing.m) {
                        SubjectTag(text: example.subject)
                        Text(example.text)
                            .font(.callout)
                            .foregroundStyle(.primary)
                            .multilineTextAlignment(.leading)
                        Spacer(minLength: 0)
                    }
                    .padding(Theme.Spacing.m)
                    .groupedCardBackground()
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityHint("填进输入框")
            }
        }
    }

    private func cardTitle(_ title: String, systemImage: String) -> some View {
        Label(title, systemImage: systemImage)
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(.secondary)
    }
}

/// 最近 7 天每天的答题数，七根小柱子，今天在最右边。
private struct WeekBars: View {
    let days: [StudyStats.DailyCount]

    var body: some View {
        let maxValue = max(days.map(\.answered).max() ?? 0, 1)
        HStack(alignment: .bottom, spacing: 4) {
            ForEach(days.indices, id: \.self) { index in
                let day = days[index]
                VStack(spacing: 2) {
                    Capsule()
                        .fill(day.answered > 0 ? AnyShapeStyle(.tint) : AnyShapeStyle(Color(.tertiarySystemFill)))
                        .frame(width: 8, height: max(4, 36 * CGFloat(day.answered) / CGFloat(maxValue)))
                    Text(day.day.formatted(.dateTime.weekday(.narrow)))
                        .font(.system(size: 9))
                        .foregroundStyle(index == days.count - 1 ? .primary : .tertiary)
                }
            }
        }
        .frame(height: 52, alignment: .bottom)
        .accessibilityHidden(true)
    }
}
