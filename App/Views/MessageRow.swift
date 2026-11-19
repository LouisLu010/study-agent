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
    /// 切换回答的版本。
    var onSelectVersion: (Int) -> Void = { _ in }
    /// 测验答完一道题。
    var onQuizResult: ([String: Any]) -> Void = { _ in }
    /// 用户消息上的"加入错题本"；为 nil 时不显示（例如还没有解答）。
    var onAddToMistakes: (() -> Void)?

    var body: some View {
        switch message.role {
        case .user:
            UserMessageView(message: message, canEdit: canEdit, onEdit: onEdit, onAddToMistakes: onAddToMistakes)
        case .assistant:
            AssistantMessageView(
                message: message,
                canRegenerate: canRegenerate,
                onRegenerate: onRegenerate,
                onAsk: onAsk,
                onSelectVersion: onSelectVersion,
                onQuizResult: onQuizResult
            )
        }
    }
}

/// 用户消息显示成右侧的气泡，内容按纯文本显示，图片显示在文字上方。
private struct UserMessageView: View {
    let message: Message
    let canEdit: Bool
    let onEdit: () -> Void
    let onAddToMistakes: (() -> Void)?

    var body: some View {
        VStack(alignment: .trailing, spacing: 6) {
            let images = message.imageData
            if images.count == 1 {
                HStack {
                    Spacer(minLength: 48)
                    ThumbnailView(data: images[0], size: 180)
                }
            } else if !images.isEmpty {
                // 最多 10 张，放不下时横向滑动。
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        ForEach(Array(images.enumerated()), id: \.offset) { _, data in
                            ThumbnailView(data: data, size: 96)
                        }
                    }
                }
                .defaultScrollAnchor(.trailing)
                .padding(.leading, 48)
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
            if let onAddToMistakes {
                Button("加入错题本", systemImage: "exclamationmark.bubble", action: onAddToMistakes)
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
    let onSelectVersion: (Int) -> Void
    let onQuizResult: ([String: Any]) -> Void

    @Environment(\.modelContext) private var context
    @State private var webHeight: CGFloat
    @State private var tappedFormula: String?
    @State private var didCopy = false
    @State private var webHandle = WebViewHandle()
    @State private var shareItem: ShareItem?
    @State private var isBookmarked = false

    init(
        message: Message,
        canRegenerate: Bool,
        onRegenerate: @escaping () -> Void,
        onAsk: @escaping (String) -> Void,
        onSelectVersion: @escaping (Int) -> Void,
        onQuizResult: @escaping ([String: Any]) -> Void
    ) {
        self.message = message
        self.canRegenerate = canRegenerate
        self.onRegenerate = onRegenerate
        self.onAsk = onAsk
        self.onSelectVersion = onSelectVersion
        self.onQuizResult = onQuizResult
        _webHeight = State(initialValue: RenderCache.heights[message.id] ?? 24)
    }

    private var isStreaming: Bool { message.status == .streaming }

    var body: some View {
        let search = message.webSearch
        VStack(alignment: .leading, spacing: 8) {
            if let search, !search.queries.isEmpty || isStreaming {
                WebSearchSummaryView(record: search, isSearching: isStreaming && message.content.isEmpty)
            }

            if !message.reasoning.isEmpty {
                ReasoningView(
                    reasoning: message.reasoning,
                    isThinking: isStreaming && message.content.isEmpty
                )
            }

            if message.content.isEmpty {
                if isStreaming && message.reasoning.isEmpty && search == nil {
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
                    onRegenerate: onRegenerate,
                    onQuizResult: onQuizResult,
                    recordsMistakes: true,
                    handle: webHandle
                )
                .frame(height: webHeight)
                // 切换版本时换一个新的 WebView，按新版本保存的组件状态重新渲染。
                .id("\(message.id)-\(message.currentVersion)")
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

            if !isStreaming, let sources = search?.displayedSources, !sources.isEmpty {
                SourceListView(sources: sources, numbered: !(search?.sources.isEmpty ?? true))
            }

            if !isStreaming && (hasActions || showsVersionSwitcher) {
                actionBar
            }

            if !isStreaming, let usage = UsageFormatting.summary(
                input: message.inputTokens, output: message.outputTokens, cost: message.costCNY,
                searches: search?.effectiveCount ?? 0
            ) {
                Text(usage)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .sheet(item: $shareItem) { item in
            ShareSheet(items: item.items)
                .presentationDetents([.medium, .large])
        }
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

    private var hasActions: Bool {
        !message.content.isEmpty && message.status != .failed
    }

    /// 只有最后一条回答、并且有多个版本时才能切换。
    private var showsVersionSwitcher: Bool {
        canRegenerate && message.versionCount > 1
    }

    private var versionSwitcher: some View {
        let count = message.versionCount
        let current = message.currentVersion
        return HStack(spacing: 4) {
            Button {
                onSelectVersion(current - 1)
            } label: {
                Image(systemName: "chevron.left")
            }
            .disabled(current == 0)
            .accessibilityLabel("上一个版本")
            Text("\(current + 1)/\(count)")
                .monospacedDigit()
            Button {
                onSelectVersion(current + 1)
            } label: {
                Image(systemName: "chevron.right")
            }
            .disabled(current >= count - 1)
            .accessibilityLabel("下一个版本")
        }
    }

    private var actionBar: some View {
        HStack(spacing: 16) {
            if showsVersionSwitcher {
                versionSwitcher
            }
            if hasActions {
                copyAndRegenerate
            }
        }
        .font(.subheadline)
        .foregroundStyle(.secondary)
        .buttonStyle(.borderless)
    }

    @ViewBuilder
    private var copyAndRegenerate: some View {
            Button {
                // 组件代码块换成可读的文字再复制。
                var text = PlainTextExporter.plainText(from: message.content)
                if let sources = message.webSearch?.sourcesText { text += "\n\n" + sources }
                UIPasteboard.general.string = text
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

            Button {
                isBookmarked = StudyCenter.toggleBookmark(message, context: context)
            } label: {
                Image(systemName: isBookmarked ? "bookmark.fill" : "bookmark")
            }
            .accessibilityLabel(isBookmarked ? "取消收藏" : "收藏")
            .onAppear { isBookmarked = StudyCenter.bookmark(for: message.id, in: context) != nil }

            Button {
                Task {
                    if let image = await webHandle.snapshot() {
                        shareItem = ShareItem(items: [image])
                    }
                }
            } label: {
                Image(systemName: "square.and.arrow.up")
            }
            .accessibilityLabel("导出为图片")
    }
}

/// 思考过程，默认折叠。
private struct ReasoningView: View {
    let reasoning: String
    let isThinking: Bool

    @State private var isExpanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                expandButton
                Spacer()
                if isExpanded {
                    Button {
                        UIPasteboard.general.string = reasoning
                    } label: {
                        Image(systemName: "doc.on.doc")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.borderless)
                    .accessibilityLabel("复制思考过程")
                }
            }

            if isExpanded {
                ReasoningText(text: reasoning)
                    .padding(.leading, 10)
                    .overlay(alignment: .leading) {
                        Rectangle()
                            .fill(.quaternary)
                            .frame(width: 2)
                    }
            }
        }
    }

    private var expandButton: some View {
            // 不加展开动画：动画会让整个聊天列表跟着重排每一帧，内容长时很卡。
            Button {
                isExpanded.toggle()
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
    }
}

/// 很长的思考过程：切成小段放进 LazyVStack，只排版屏幕附近的段落。
/// 不开 textSelection：它会让长文本的布局慢很多；需要原文时用上面的复制按钮。
private struct ReasoningText: View {
    let text: String

    var body: some View {
        let chunks = TextChunker.split(text)
        LazyVStack(alignment: .leading, spacing: 0) {
            ForEach(chunks.indices, id: \.self) { index in
                Text(chunks[index])
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }
}

/// 回答上方的一行：生成时显示"正在搜索：…"，完成后显示"搜索了 N 次"，点开列出搜过的词。
private struct WebSearchSummaryView: View {
    let record: WebSearchRecord
    let isSearching: Bool

    @State private var isExpanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Button {
                isExpanded.toggle()
            } label: {
                HStack(spacing: 6) {
                    if isSearching {
                        ProgressView()
                            .controlSize(.small)
                    } else {
                        Image(systemName: "globe")
                    }
                    Text(title)
                        .lineLimit(1)
                    if !record.queries.isEmpty {
                        Image(systemName: "chevron.right")
                            .font(.caption)
                            .rotationEffect(.degrees(isExpanded ? 90 : 0))
                    }
                }
                .font(.subheadline)
                .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .disabled(record.queries.isEmpty)

            if isExpanded {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(record.queries.indices, id: \.self) { index in
                        Label(record.queries[index], systemImage: "magnifyingglass")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(.leading, 10)
                .overlay(alignment: .leading) {
                    Rectangle()
                        .fill(.quaternary)
                        .frame(width: 2)
                }
            }
        }
    }

    private var title: String {
        if isSearching {
            if let query = record.queries.last { return "正在搜索：\(query)" }
            return "正在搜索…"
        }
        return "搜索了 \(record.effectiveCount) 次"
    }
}

/// 回答末尾的出处列表。编号和正文里的角标一致；点按用系统浏览器打开。
private struct SourceListView: View {
    let sources: [WebSource]
    /// 有引用时按 [1] [2] 编号；只有搜索结果时不编号。
    let numbered: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("出处")
                .font(.caption)
                .foregroundStyle(.secondary)
            ForEach(sources.indices, id: \.self) { index in
                let source = sources[index]
                if let url = URL(string: source.url) {
                    Link(destination: url) {
                        HStack(alignment: .firstTextBaseline, spacing: 6) {
                            if numbered {
                                Text("[\(index + 1)]")
                                    .monospacedDigit()
                                    .foregroundStyle(.secondary)
                            }
                            VStack(alignment: .leading, spacing: 1) {
                                Text(source.displayTitle)
                                    .lineLimit(2)
                                    .multilineTextAlignment(.leading)
                                if let host = source.host, host != source.displayTitle {
                                    Text(host)
                                        .font(.caption2)
                                        .foregroundStyle(.tertiary)
                                }
                            }
                        }
                        .font(.footnote)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }
        }
        .padding(10)
        .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 12))
    }
}
