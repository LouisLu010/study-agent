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
                                onAsk: ask
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
