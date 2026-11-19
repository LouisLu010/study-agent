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
    @State private var showInstructions = false
    @State private var shareItem: ShareItem?
    @State private var addingMistake: MistakeDraft?

    private let bottomID = "bottom"

    var body: some View {
        let messages = conversation.sortedMessages
        let isGenerating = generation.isGenerating(conversation)
        let lastAssistantID = messages.last(where: { $0.role == .assistant })?.id

        VStack(spacing: 0) {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 20) {
                        ForEach(messages) { message in
                            MessageRow(
                                message: message,
                                canRegenerate: !isGenerating && message.id == lastAssistantID,
                                canEdit: !isGenerating,
                                onRegenerate: { regenerate(message) },
                                onEdit: { editingMessage = message },
                                onAsk: ask,
                                onSelectVersion: { index in
                                    generation.selectVersion(index, of: message, in: conversation, context: context)
                                },
                                onQuizResult: { payload in
                                    StudyCenter.recordQuizResult(payload, conversation: conversation, message: message, context: context)
                                },
                                onAddToMistakes: solution(for: message).map { reply in
                                    { addingMistake = MistakeDraft(question: message, solution: reply) }
                                }
                            )
                        }
                        Color.clear
                            .frame(height: 1)
                            .id(bottomID)
                    }
                    .padding()
                    .frame(maxWidth: 820)
                    .frame(maxWidth: .infinity)
                }
                .scrollDismissesKeyboard(.interactively)
                .defaultScrollAnchor(.bottom, for: .initialOffset)
                .defaultScrollAnchor(.bottom, for: .sizeChanges)
                .onChange(of: messages.count) {
                    withAnimation { proxy.scrollTo(bottomID, anchor: .bottom) }
                }
            }

            ComposerView(
                text: $draft,
                images: $draftImages,
                imagesAllowed: conversation.model?.supportsImages ?? false,
                isGenerating: isGenerating,
                canSend: canSend,
                onSend: send,
                onStop: { generation.stop(conversation) },
                onImagesNotAllowed: { errorMessage = GenerationError.modelDoesNotSupportImages.localizedDescription }
            )
            .frame(maxWidth: 820)
            .frame(maxWidth: .infinity)
        }
        .navigationTitle(conversation.title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                ModelPickerMenu(selection: $conversation.model)
            }
        }
        // 点导航栏标题弹出的菜单：会话级别的操作。
        .toolbarTitleMenu {
            Button(
                conversation.instructions.isEmpty ? "添加会话提示词" : "编辑会话提示词",
                systemImage: "text.badge.star"
            ) {
                showInstructions = true
            }
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
                cost: total.cost
            ) {
                Section("本会话用量") {
                    Text(usage)
                }
            }
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
            try generation.send(text, images: images, in: conversation, context: context)
            draft = ""
            draftImages = []
        }
    }

    /// 用户消息后面紧跟的那条已经生成完的 AI 回答，作为错题的解答。生成中或失败时返回 nil。
    private func solution(for message: Message) -> Message? {
        guard message.role == .user else { return nil }
        let messages = conversation.sortedMessages
        guard let index = messages.firstIndex(where: { $0.id == message.id }), index + 1 < messages.count else { return nil }
        let reply = messages[index + 1]
        guard reply.role == .assistant, reply.status == .complete || reply.status == .stopped, !reply.content.isEmpty else {
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
        perform { try generation.send(text, in: conversation, context: context) }
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
                    Text("重新发送后，这条消息之后的所有内容都会被删除。" + (hasImages ? "原来的图片会保留。" : ""))
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
                } footer: {
                    Text("只对这个会话生效，从下一条消息开始使用。例如：这个会话只讲高中物理，讲解时多举生活中的例子。")
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
                } footer: {
                    Text("会保存这条提问和后面那条 AI 解答。复习时先看题目，自己想好后再看解答。")
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
