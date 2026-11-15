import StudyKit
import SwiftData
import SwiftUI

struct ChatView: View {
    @Bindable var conversation: Conversation

    @Environment(\.modelContext) private var context
    @Environment(GenerationCenter.self) private var generation
    @State private var draft = ""
    @State private var errorMessage: String?

    private let bottomID = "bottom"

    var body: some View {
        let messages = conversation.sortedMessages

        VStack(spacing: 0) {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 20) {
                        ForEach(messages) { message in
                            MessageRow(message: message)
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
                .onAppear {
                    proxy.scrollTo(bottomID, anchor: .bottom)
                }
                .onChange(of: scrollToken(messages)) {
                    proxy.scrollTo(bottomID, anchor: .bottom)
                }
            }

            ComposerView(
                text: $draft,
                isGenerating: generation.isGenerating(conversation),
                canSend: canSend,
                onSend: send,
                onStop: { generation.stop(conversation) }
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
            "无法发送",
            isPresented: Binding(
                get: { errorMessage != nil },
                set: { if !$0 { errorMessage = nil } }
            )
        ) {
            Button("好", role: .cancel) {}
        } message: {
            Text(errorMessage ?? "")
        }
    }

    private var trimmedDraft: String {
        draft.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var canSend: Bool {
        !trimmedDraft.isEmpty && conversation.model != nil
    }

    /// 消息数量或最后一条消息长度变化时滚动到底部。
    private func scrollToken(_ messages: [Message]) -> String {
        "\(messages.count)-\(messages.last?.content.count ?? 0)-\(messages.last?.statusRaw ?? "")"
    }

    private func send() {
        let text = trimmedDraft
        guard !text.isEmpty else { return }
        do {
            try generation.send(text, in: conversation, context: context)
            draft = ""
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
