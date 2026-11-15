import StudyKit
import SwiftUI
import UIKit

struct MessageRow: View {
    let message: Message

    var body: some View {
        switch message.role {
        case .user: UserMessageView(message: message)
        case .assistant: AssistantMessageView(message: message)
        }
    }
}

/// 用户消息显示成右侧的气泡，内容按纯文本显示。
private struct UserMessageView: View {
    let message: Message

    var body: some View {
        HStack {
            Spacer(minLength: 48)
            Text(message.content)
                .textSelection(.enabled)
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .background(Color.accentColor.opacity(0.15), in: RoundedRectangle(cornerRadius: 18))
                .contextMenu {
                    Button("复制", systemImage: "doc.on.doc") {
                        UIPasteboard.general.string = message.content
                    }
                }
        }
    }
}

/// 模型消息：WebView 渲染的正文，加上状态和操作栏。
private struct AssistantMessageView: View {
    let message: Message

    @State private var webHeight: CGFloat
    @State private var tappedFormula: String?
    @State private var didCopy = false

    init(message: Message) {
        self.message = message
        _webHeight = State(initialValue: RenderCache.heights[message.id] ?? 24)
    }

    private var isStreaming: Bool { message.status == .streaming }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if !message.reasoning.isEmpty {
                ReasoningView(
                    reasoning: message.reasoning,
                    isThinking: isStreaming && message.content.isEmpty
                )
            }

            if message.content.isEmpty {
                if isStreaming && message.reasoning.isEmpty {
                    ProgressView()
                        .frame(height: 24)
                }
            } else {
                MessageWebView(
                    messageID: message.id,
                    content: message.content,
                    isStreaming: isStreaming,
                    height: $webHeight,
                    onFormulaTap: { tappedFormula = $0 }
                )
                .frame(height: webHeight)
            }

            switch message.status {
            case .failed:
                Label(message.errorText ?? "生成失败。", systemImage: "exclamationmark.triangle")
                    .font(.callout)
                    .foregroundStyle(.red)
            case .stopped:
                Text("已停止生成")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            case .complete, .streaming:
                EmptyView()
            }

            if !isStreaming && !message.content.isEmpty {
                actionBar
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .confirmationDialog(
            "公式",
            isPresented: Binding(
                get: { tappedFormula != nil },
                set: { if !$0 { tappedFormula = nil } }
            ),
            titleVisibility: .visible,
            presenting: tappedFormula
        ) { tex in
            Button("复制 LaTeX 源码") {
                UIPasteboard.general.string = tex
            }
        } message: { tex in
            Text(tex)
        }
    }

    private var actionBar: some View {
        HStack(spacing: 16) {
            Button {
                UIPasteboard.general.string = message.content
                didCopy = true
                Task {
                    try? await Task.sleep(for: .seconds(1.5))
                    didCopy = false
                }
            } label: {
                Image(systemName: didCopy ? "checkmark" : "doc.on.doc")
            }
            .accessibilityLabel("复制")
        }
        .font(.subheadline)
        .foregroundStyle(.secondary)
        .buttonStyle(.borderless)
    }
}

/// 思考过程，默认折叠。
private struct ReasoningView: View {
    let reasoning: String
    let isThinking: Bool

    @State private var isExpanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Button {
                withAnimation(.easeInOut(duration: 0.2)) { isExpanded.toggle() }
            } label: {
                HStack(spacing: 6) {
                    if isThinking {
                        ProgressView()
                            .controlSize(.small)
                    } else {
                        Image(systemName: "brain")
                    }
                    Text(isThinking ? "正在思考…" : "思考过程")
                    Image(systemName: "chevron.right")
                        .font(.caption)
                        .rotationEffect(.degrees(isExpanded ? 90 : 0))
                }
                .font(.subheadline)
                .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)

            if isExpanded {
                Text(reasoning)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .padding(.leading, 10)
                    .overlay(alignment: .leading) {
                        Rectangle()
                            .fill(.quaternary)
                            .frame(width: 2)
                    }
            }
        }
    }
}
