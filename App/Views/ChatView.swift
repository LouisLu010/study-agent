import StudyKit
import SwiftData
import SwiftUI

struct ChatView: View {
    @Bindable var conversation: Conversation

    @Environment(\.modelContext) private var context
    @Environment(GenerationCenter.self) private var generation
    @State private var draft = ""
    @State private var draftImages: [PendingImage] = []
    @State private var errorMessage: String?
    @State private var editingMessage: Message?
    @State private var noteDraft: NoteDraftRequest?
    @State private var showInstructions = false
    @State private var shareItem: ShareItem?
    @State private var addingMistake: MistakeDraft?
    @AppStorage(AppSettingsKey.defaultPersonaID) private var defaultPersonaID = Persona.standardID
    /// 往上翻超过一屏时显示"回到底部"按钮。
    @State private var showJumpToBottom = false
    /// 每发一条消息加一，用来触发震动。
    @State private var sendCount = 0
    /// 测验答完一道题，用来触发答对或答错的震动。
    @State private var quizFeedback: QuizFeedback?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// 聊天列表的滚动位置。"回到底部"和发新消息时用它滚到内容的底边。
    /// 以前用 ScrollViewReader 滚到列表末尾那个 id：中间的回答在 LazyVStack 里还没建出来、高度是估的，
    /// 离得远时滚不到底，看起来像按钮没反应。按边滚不依赖某一行是否已经建出来。
    @State private var scrollPosition = ScrollPosition(edge: .bottom)

    /// 消息出现的动画。打开"减弱动态效果"后不用动画。
    private var messageAnimation: Animation? {
        reduceMotion ? nil : .smooth(duration: 0.35)
    }

    var body: some View {
        let messages = conversation.sortedMessages
        let isGenerating = generation.isGenerating(conversation)
        let lastAssistantID = messages.last(where: { $0.role == .assistant })?.id
        let lastReplyCompleted = messages.last?.status == .complete

        Group {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: Theme.Spacing.xl) {
                    ForEach(messages) { message in
                        MessageRow(
                            message: message,
                            canRegenerate: !isGenerating && message.id == lastAssistantID,
                            canEdit: !isGenerating,
                            onRegenerate: { regenerate(message) },
                            onContinue: { perform { try generation.continueReply(message, in: conversation, context: context) } },
                            onEdit: { editingMessage = message },
                            onAsk: ask,
                            onSelectVersion: { index in
                                generation.selectVersion(index, of: message, in: conversation, context: context)
                            },
                            onQuizResult: { payload in
                                quizFeedback = QuizFeedback(correct: (payload["correct"] as? NSNumber)?.boolValue ?? false)
                                StudyCenter.recordQuizResult(payload, conversation: conversation, message: message, context: context)
                            },
                            onAddToMistakes: solution(for: message).map { reply in
                                { addingMistake = MistakeDraft(question: message, solution: reply) }
                            }
                        )
                        .transition(
                            message.role == .user
                                ? AnyTransition.move(edge: .bottom).combined(with: .opacity)
                                : AnyTransition.opacity
                        )
                    }
                }
                .padding()
                .frame(maxWidth: 820)
                .frame(maxWidth: .infinity)
            }
            .scrollPosition($scrollPosition)
            .scrollDismissesKeyboard(.interactively)
            .defaultScrollAnchor(.bottom, for: .initialOffset)
            .defaultScrollAnchor(.bottom, for: .sizeChanges)
            .onChange(of: messages.count) {
                scrollToBottom()
            }
            .onScrollGeometryChange(for: Bool.self) { geometry in
                geometry.contentSize.height - geometry.visibleRect.maxY > geometry.containerSize.height
            } action: { _, isFar in
                withAnimation(reduceMotion ? nil : .snappy) { showJumpToBottom = isFar }
            }
            .overlay {
                if messages.isEmpty {
                    EmptyChatView { draft = $0 }
                }
            }
            .overlay(alignment: .bottom) {
                if showJumpToBottom && !messages.isEmpty {
                    jumpToBottomButton
                        .padding(.bottom, Theme.Spacing.s)
                        .transition(.scale(scale: 0.6).combined(with: .opacity))
                }
            }
            .bottomBar {
                composer(isGenerating: isGenerating)
            }
        }
        .sensoryFeedback(.impact(weight: .light), trigger: sendCount)
        .sensoryFeedback(.success, trigger: isGenerating) { wasGenerating, nowGenerating in
            // 回答正常生成完时轻震一下；停止或失败时不震。
            wasGenerating && !nowGenerating && lastReplyCompleted
        }
        .sensoryFeedback(trigger: quizFeedback) { _, feedback in
            feedback.map { $0.correct ? SensoryFeedback.success : SensoryFeedback.error }
        }
        .navigationTitle(conversation.title)
        .navigationBarTitleDisplayMode(.inline)
        // 模型名在输入框里（第八版），导航栏右边不放东西。
        // 点导航栏标题弹出的菜单：会话级别的操作。
        .toolbarTitleMenu {
            ConversationPersonaMenu(
                personaID: Binding(
                    get: { conversation.personaID },
                    set: { conversation.personaID = $0; try? context.save() }
                ),
                defaultPersona: Persona.resolve(conversationID: "", defaultID: defaultPersonaID)
            )
            Button(
                conversation.instructions.isEmpty ? "添加会话提示词" : "编辑会话提示词",
                systemImage: "text.badge.star"
            ) {
                showInstructions = true
            }
            Button("整理成资料", systemImage: "doc.text.magnifyingglass") {
                noteDraft = .conversation(conversation)
            }
            .disabled(conversation.sortedMessages.isEmpty || isGenerating)
            Button("导出为 Markdown", systemImage: "square.and.arrow.up") {
                do {
                    shareItem = ShareItem(items: [try ConversationExporter.markdownFile(for: conversation)])
                } catch {
                    errorMessage = "导出失败：\(error.localizedDescription)"
                }
            }
            .disabled(conversation.sortedMessages.isEmpty)
            let total = conversation.usageTotal
            if let usage = UsageFormatting.summary(
                input: total.input > 0 ? total.input : nil,
                output: total.output > 0 ? total.output : nil,
                cost: total.cost,
                searches: total.searches
            ) {
                Section("本会话用量") {
                    Text(usage)
                }
            }
        }
        .sheet(item: $noteDraft) { request in
            NoteDraftSheet(request: request)
        }
        .sheet(isPresented: $showInstructions) {
            ConversationInstructionsSheet(conversation: conversation)
        }
        .sheet(item: $addingMistake) { draft in
            AddMistakeSheet { note in
                StudyCenter.addManualMistake(
                    question: draft.question, solution: draft.solution, note: note,
                    conversation: conversation, context: context
                )
            }
        }
        .sheet(item: $shareItem) { item in
            ShareSheet(items: item.items)
                .presentationDetents([.medium, .large])
        }
        .alert(
            "提示",
            isPresented: Binding(
                get: { errorMessage != nil },
                set: { if !$0 { errorMessage = nil } }
            )
        ) {
            Button("好", role: .cancel) {}
        } message: {
            Text(errorMessage ?? "")
        }
        .sheet(item: $editingMessage) { message in
            EditMessageSheet(originalText: message.content, hasImages: !message.imageData.isEmpty) { newText in
                perform { try generation.resend(message, newText: newText, in: conversation, context: context) }
            }
        }
    }

    /// 滚到底。中间的回答滚进屏幕时才建出 WebView、量出真实高度，内容会跟着变长，
    /// 所以等这些高度报上来以后再补滚一次（不带动画），保证停在最底下。
    private func scrollToBottom() {
        withAnimation(messageAnimation) { scrollPosition.scrollTo(edge: .bottom) }
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(450))
            scrollPosition.scrollTo(edge: .bottom)
        }
    }

    private var jumpToBottomButton: some View {
        Button {
            scrollToBottom()
        } label: {
            Image(systemName: "arrow.down")
                .font(.headline)
                .foregroundStyle(.primary)
                .frame(width: 44, height: 44)
                .glassSurface(in: Circle(), interactive: true)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("回到底部")
    }

    private func composer(isGenerating: Bool) -> some View {
        ComposerView(
            text: $draft,
            images: $draftImages,
            imagesAllowed: conversation.model?.supportsImages ?? false,
            isGenerating: isGenerating,
            canSend: canSend,
            onSend: send,
            onStop: { generation.stop(conversation) },
            onImagesNotAllowed: { errorMessage = GenerationError.modelDoesNotSupportImages.localizedDescription },
            webSearchEnabled: $conversation.webSearchEnabled,
            webSearchAllowed: conversation.model?.supportsWebSearch ?? false,
            onWebSearchNotAllowed: {
                errorMessage = "当前模型不支持联网搜索。请切换到支持的模型，或在设置里为这个模型打开\"支持联网搜索\"。"
            },
            model: $conversation.model
        )
        .frame(maxWidth: 820)
        .frame(maxWidth: .infinity)
    }

    private var trimmedDraft: String {
        draft.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var canSend: Bool {
        (!trimmedDraft.isEmpty || !draftImages.isEmpty) && conversation.model != nil
    }

    private func send() {
        guard canSend else { return }
        let text = trimmedDraft
        let images = draftImages.map(\.data)
        perform {
            try withAnimation(messageAnimation) {
                try generation.send(text, images: images, in: conversation, context: context)
            }
            draft = ""
            draftImages = []
            sendCount += 1
        }
    }

    /// 用户消息后面紧跟的那条已经生成完的 AI 回答，作为错题的解答。生成中或失败时返回 nil。
    private func solution(for message: Message) -> Message? {
        guard message.role == .user else { return nil }
        let messages = conversation.sortedMessages
        guard let index = messages.firstIndex(where: { $0.id == message.id }), index + 1 < messages.count else { return nil }
        let reply = messages[index + 1]
        guard reply.role == .assistant, [.complete, .stopped, .interrupted].contains(reply.status), !reply.content.isEmpty else {
            return nil
        }
        return reply
    }

    /// 组件里的"问问 AI"：直接发出，不经过输入框。
    private func ask(_ text: String) {
        if generation.isGenerating(conversation) {
            errorMessage = "请等当前回答生成完再提问。"
            return
        }
        perform {
            try withAnimation(messageAnimation) {
                try generation.send(text, in: conversation, context: context)
            }
            sendCount += 1
        }
    }

    private func regenerate(_ message: Message) {
        perform { try generation.regenerate(message, in: conversation, context: context) }
    }

    private func perform(_ action: () throws -> Void) {
        do {
            try action()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

/// 编辑一条用户消息的文字，确认后删掉它之后的消息并重新发送。
private struct EditMessageSheet: View {
    let originalText: String
    let hasImages: Bool
    let onSubmit: (String) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var text: String
    @FocusState private var isFocused: Bool

    init(originalText: String, hasImages: Bool, onSubmit: @escaping (String) -> Void) {
        self.originalText = originalText
        self.hasImages = hasImages
        self.onSubmit = onSubmit
        _text = State(initialValue: originalText)
    }

    private var trimmed: String {
        text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextEditor(text: $text)
                        .frame(minHeight: 160)
                        .focused($isFocused)
                } footer: {
                    Text("重新发送会删掉这条之后的所有内容" + (hasImages ? "，图片保留。" : "。"))
                }
            }
            .navigationTitle("编辑消息")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("发送") {
                        dismiss()
                        onSubmit(trimmed)
                    }
                    .disabled(trimmed.isEmpty && !hasImages)
                }
            }
            .onAppear { isFocused = true }
        }
        .presentationDetents([.medium, .large])
    }
}

/// 编辑只对这个会话生效的提示词，接在用户提示词后面发送。
private struct ConversationInstructionsSheet: View {
    @Bindable var conversation: Conversation

    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @State private var text = ""

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextEditor(text: $text)
                        .frame(minHeight: 160)
                }
            }
            .navigationTitle("会话提示词")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存") {
                        conversation.instructions = text.trimmingCharacters(in: .whitespacesAndNewlines)
                        try? context.save()
                        dismiss()
                    }
                }
            }
            .onAppear { text = conversation.instructions }
        }
        .presentationDetents([.medium, .large])
    }
}

/// 测验答完一道题的结果。每次都是新的 id，同样的对错连续出现也会触发震动。
private struct QuizFeedback: Equatable {
    let id = UUID()
    let correct: Bool
}

struct MistakeDraft: Identifiable {
    let id = UUID()
    let question: Message
    let solution: Message
}

/// 把一道自己问过的题加入错题本，可以写一句备注。
private struct AddMistakeSheet: View {
    let onSave: (String) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var note = ""

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("例如：符号判断错了", text: $note, axis: .vertical)
                        .lineLimit(2...5)
                } header: {
                    Text("备注（可选）")
                }
            }
            .navigationTitle("加入错题本")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("加入") {
                        onSave(note)
                        dismiss()
                    }
                }
            }
        }
        .presentationDetents([.medium])
    }
}
