import StudyKit
import SwiftUI
import UIKit

struct MessageRow: View {
    let message: Message
    /// 只有最后一条模型消息可以重新生成。
    var canRegenerate = false
    var canEdit = false
    var onRegenerate: () -> Void = {}
    var onEdit: () -> Void = {}
    /// 组件里的"问问 AI"按钮：以用户的名义发一条消息。
    var onAsk: (String) -> Void = { _ in }

    var body: some View {
        switch message.role {
        case .user:
            UserMessageView(message: message, canEdit: canEdit, onEdit: onEdit)
        case .assistant:
            AssistantMessageView(
                message: message,
                canRegenerate: canRegenerate,
                onRegenerate: onRegenerate,
                onAsk: onAsk
            )
        }
    }
}

/// 用户消息显示成右侧的气泡，内容按纯文本显示，图片显示在文字上方。
private struct UserMessageView: View {
    let message: Message
    let canEdit: Bool
    let onEdit: () -> Void

    var body: some View {
        VStack(alignment: .trailing, spacing: 6) {
            let images = message.imageData
            if !images.isEmpty {
                HStack(spacing: 6) {
                    Spacer(minLength: 48)
                    ForEach(Array(images.enumerated()), id: \.offset) { _, data in
                        ThumbnailView(data: data, size: images.count == 1 ? 180 : 96)
                    }
                }
            }

            if !message.content.isEmpty {
                HStack {
                    Spacer(minLength: 48)
                    Text(message.content)
                        .textSelection(.enabled)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 10)
                        .background(Color.accentColor.opacity(0.15), in: RoundedRectangle(cornerRadius: 18))
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .trailing)
        .contextMenu {
            if !message.content.isEmpty {
                Button("复制", systemImage: "doc.on.doc") {
                    UIPasteboard.general.string = message.content
                }
            }
            if canEdit {
                Button("编辑后重新发送", systemImage: "pencil", action: onEdit)
            }
        }
    }
}

/// 模型消息：WebView 渲染的正文，加上状态和操作栏。
private struct AssistantMessageView: View {
    let message: Message
    let canRegenerate: Bool
    let onRegenerate: () -> Void
    let onAsk: (String) -> Void

    @Environment(\.modelContext) private var context
    @State private var webHeight: CGFloat
    @State private var tappedFormula: String?
    @State private var didCopy = false

    init(
        message: Message,
        canRegenerate: Bool,
        onRegenerate: @escaping () -> Void,
        onAsk: @escaping (String) -> Void
    ) {
        self.message = message
        self.canRegenerate = canRegenerate
        self.onRegenerate = onRegenerate
        self.onAsk = onAsk
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
                    componentStateJSON: message.componentStateJSON,
                    canRegenerate: canRegenerate,
                    height: $webHeight,
                    onFormulaTap: { tappedFormula = $0 },
                    onComponentState: { key, state in
                        message.componentStateJSON = ComponentStateStore.updating(
                            message.componentStateJSON, key: key, state: state
                        )
                        try? context.save()
                    },
                    onAsk: onAsk,
                    onRegenerate: onRegenerate
                )
                .frame(height: webHeight)
            }

            switch message.status {
            case .failed:
                VStack(alignment: .leading, spacing: 8) {
                    Label(message.errorText ?? "生成失败。", systemImage: "exclamationmark.triangle")
                        .font(.callout)
                        .foregroundStyle(.red)
                    if canRegenerate {
                        Button("重试", systemImage: "arrow.clockwise", action: onRegenerate)
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                    }
                }
            case .stopped:
                Text("已停止生成")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            case .complete, .streaming:
                EmptyView()
            }

            if !isStreaming && !message.content.isEmpty && message.status != .failed {
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
                // 组件代码块换成可读的文字再复制。
                UIPasteboard.general.string = PlainTextExporter.plainText(from: message.content)
                didCopy = true
                Task {
                    try? await Task.sleep(for: .seconds(1.5))
                    didCopy = false
                }
            } label: {
                Image(systemName: didCopy ? "checkmark" : "doc.on.doc")
            }
            .accessibilityLabel("复制")

            if canRegenerate {
                Button(action: onRegenerate) {
                    Image(systemName: "arrow.clockwise")
                }
                .accessibilityLabel("重新生成")
            }
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
