import StudyKit
import SwiftUI
import UIKit

struct MessageRow: View {
    let message: Message
    /// 只有最后一条模型消息可以重新生成。
    var canRegenerate = false
    var canEdit = false
    var onRegenerate: () -> Void = {}
    /// 被系统中断的最后一条回答：接着写。
    var onContinue: () -> Void = {}
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
                onContinue: onContinue,
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
                        // 第八版：中性浅灰，深色模式是深灰。
                        .background(Color(.secondarySystemFill), in: RoundedRectangle(cornerRadius: Theme.fieldRadius, style: .continuous))
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
    let onContinue: () -> Void
    let onAsk: (String) -> Void
    let onSelectVersion: (Int) -> Void
    let onQuizResult: ([String: Any]) -> Void

    @Environment(\.modelContext) private var context
    @State private var keeper = BackgroundKeeper.shared
    @State private var webHeight: CGFloat
    @State private var tappedFormula: String?
    @State private var didCopy = false
    @State private var webHandle = WebViewHandle()
    @State private var shareItem: ShareItem?
    @State private var isBookmarked = false
    /// 每点一次收藏加一，只在点按时播放图标动画（打开页面时读到已收藏不播放）。
    @State private var bookmarkTaps = 0
    @State private var noteDraft: NoteDraftRequest?
    /// 正在全屏显示的组件，和它在这条消息里的组件键。
    @State private var fullscreen: FullscreenComponent?
    @State private var fullscreenKey: String?

    init(
        message: Message,
        canRegenerate: Bool,
        onRegenerate: @escaping () -> Void,
        onContinue: @escaping () -> Void,
        onAsk: @escaping (String) -> Void,
        onSelectVersion: @escaping (Int) -> Void,
        onQuizResult: @escaping ([String: Any]) -> Void
    ) {
        self.message = message
        self.canRegenerate = canRegenerate
        self.onRegenerate = onRegenerate
        self.onContinue = onContinue
        self.onAsk = onAsk
        self.onSelectVersion = onSelectVersion
        self.onQuizResult = onQuizResult
        _webHeight = State(initialValue: RenderCache.heights[message.id] ?? 24)
    }

    private var isStreaming: Bool { message.status == .streaming }

    var body: some View {
        let search = message.webSearch
        VStack(alignment: .leading, spacing: 8) {
            if !message.modelName.isEmpty {
                Text(message.modelName)
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            if let search, !search.queries.isEmpty || isStreaming {
                WebSearchSummaryView(record: search, isSearching: isStreaming && message.content.isEmpty)
            }
            // 出处卡片横排在正文上方（第八版），拿到出处就显示。复制和导出 Markdown 仍在末尾附文字版出处。
            if let search, !search.displayedSources.isEmpty {
                SourceStripView(sources: search.displayedSources, numbered: !search.sources.isEmpty)
            }

            if !message.reasoning.isEmpty {
                ReasoningView(
                    reasoning: message.reasoning,
                    isThinking: isStreaming && message.content.isEmpty
                )
            }

            if message.content.isEmpty {
                if isStreaming && message.reasoning.isEmpty && search == nil {
                    ActivityOrb(activity: .working)
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
                    handle: webHandle,
                    onFullscreen: { key, markdown, state in
                        fullscreenKey = key
                        fullscreen = FullscreenComponent(key: key, markdown: markdown, stateJSON: state)
                    }
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
            case .interrupted:
                VStack(alignment: .leading, spacing: 8) {
                    Label("回答被系统中断", systemImage: "pause.circle")
                        .font(.callout)
                        .foregroundStyle(.orange)
                    if canRegenerate {
                        Button("继续生成", systemImage: "arrow.right.circle", action: onContinue)
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                    }
                }
            case .streaming:
                // 生成超过两分钟后系统没批准后台运行：切走可能会中断，提示一行小字。
                if keeper.cannotStayInBackground {
                    Text("系统没有批准后台运行，切到别的 App 约 30 秒后回答可能会中断。")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            case .complete:
                EmptyView()
            }

            if !isStreaming && (hasActions || showsVersionSwitcher) {
                actionBar
            }

            if !isStreaming, let usage = UsageFormatting.summary(
                input: message.inputTokens, output: message.outputTokens, cost: message.costCNY,
                searches: search?.effectiveCount ?? 0, cached: message.cachedInputTokens
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
        .sheet(item: $noteDraft) { request in
            NoteDraftSheet(request: request)
        }
        .fullScreenCover(item: $fullscreen, onDismiss: {
            // 全屏页里改过的参数、拖过的点交回给正文里的组件。
            if let key = fullscreenKey {
                webHandle.applyState(key: key, stateJSON: message.componentStateJSON)
            }
            fullscreenKey = nil
        }) { request in
            ComponentFullscreenView(request: request) { state in
                message.componentStateJSON = ComponentStateStore.updating(message.componentStateJSON, key: request.key, state: state)
                try? context.save()
            }
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
        // 最后一条回答的操作栏正常显示，之前的淡一些，不抢正文。
        .foregroundStyle(canRegenerate ? AnyShapeStyle(.secondary) : AnyShapeStyle(.tertiary))
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
                    .contentTransition(.symbolEffect(.replace))
            }
            .accessibilityLabel("复制")
            .sensoryFeedback(.success, trigger: didCopy) { _, copied in copied }

            if canRegenerate {
                Button(action: onRegenerate) {
                    Image(systemName: "arrow.clockwise")
                }
                .accessibilityLabel("重新生成")
            }

            Button {
                isBookmarked = StudyCenter.toggleBookmark(message, context: context)
                bookmarkTaps += 1
            } label: {
                Image(systemName: isBookmarked ? "bookmark.fill" : "bookmark")
                    .contentTransition(.symbolEffect(.replace))
                    .symbolEffect(.bounce, value: bookmarkTaps)
            }
            .accessibilityLabel(isBookmarked ? "取消收藏" : "收藏")
            .onAppear { isBookmarked = StudyCenter.bookmark(for: message.id, in: context) != nil }

            Button {
                noteDraft = .reply(message)
            } label: {
                Image(systemName: "doc.text.magnifyingglass")
            }
            .accessibilityLabel("整理成资料")

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

/// 思考过程。聊天列表里只显示一行标题，生成时下面滚动显示最后两行；全文在单独的面板里看。
/// 不在列表里展开长文字：几万字的思考过程放在聊天列表里，滑动时 SwiftUI 要一直排版，很卡。
private struct ReasoningView: View {
    let reasoning: String
    let isThinking: Bool

    @State private var showsFull = false

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
            Button {
                showsFull = true
            } label: {
                HStack(spacing: 6) {
                    if isThinking {
                        ActivityOrb(activity: .reasoning, size: 18)
                    } else {
                        Image(systemName: "brain")
                    }
                    Text(isThinking ? "正在思考…" : "思考过程")
                    Image(systemName: "chevron.right")
                        .font(.caption)
                }
                .font(.subheadline)
                .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .accessibilityHint("查看完整的思考过程")

            if isThinking {
                Text(Self.preview(of: reasoning))
                    .font(.footnote)
                    .foregroundStyle(.tertiary)
                    .lineLimit(2, reservesSpace: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.leading, Theme.Spacing.s)
                    .overlay(alignment: .leading) {
                        Rectangle()
                            .fill(.quaternary)
                            .frame(width: 2)
                    }
            }
        }
        .sheet(isPresented: $showsFull) {
            ReasoningSheet(reasoning: reasoning, isThinking: isThinking)
        }
    }

    /// 最后两行。只看末尾一小段，不管思考过程多长都很快。
    static func preview(of text: String) -> String {
        let tail = text.suffix(240)
        let lines = tail.split(separator: "\n", omittingEmptySubsequences: true).suffix(2)
        return lines.joined(separator: "\n")
    }
}

/// 完整的思考过程，在自己的滚动视图里按段懒加载。
private struct ReasoningSheet: View {
    let reasoning: String
    let isThinking: Bool

    @Environment(\.dismiss) private var dismiss
    @State private var didCopy = false

    var body: some View {
        NavigationStack {
            ScrollView {
                ReasoningText(text: reasoning)
                    .padding(Theme.Spacing.l)
            }
            .navigationTitle(isThinking ? "正在思考…" : "思考过程")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("完成") { dismiss() }
                }
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        UIPasteboard.general.string = reasoning
                        didCopy = true
                    } label: {
                        Image(systemName: didCopy ? "checkmark" : "doc.on.doc")
                            .contentTransition(.symbolEffect(.replace))
                    }
                    .accessibilityLabel("复制思考过程")
                    .sensoryFeedback(.success, trigger: didCopy) { _, copied in copied }
                }
            }
        }
        .presentationDetents([.medium, .large])
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
                        ActivityOrb(activity: .searching, size: 18)
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

/// 出处列表：资料里的出处，以及出处卡片上"全部 N 个"打开的列表。编号和正文里的角标一致；点按用系统浏览器打开。
struct SourceListView: View {
    let sources: [WebSource]
    /// 有引用时按 [1] [2] 编号；只有搜索结果时不编号。
    let numbered: Bool
    /// 不为 nil 时每个出处后面有删除按钮。
    var onDelete: ((Int) -> Void)?

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
                    .overlay(alignment: .trailing) {
                        if let onDelete {
                            Button(role: .destructive) {
                                onDelete(index)
                            } label: {
                                Image(systemName: "minus.circle.fill")
                                    .foregroundStyle(.red)
                            }
                            .buttonStyle(.borderless)
                            .accessibilityLabel("删除出处")
                        }
                    }
                }
            }
        }
        .padding(Theme.Spacing.m)
        .cardBackground()
    }
}
