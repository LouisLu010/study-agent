import StudyKit
import SwiftData
import SwiftUI

/// 用 WebView 渲染一段固定的内容（错题、收藏），高度跟着内容走。
struct RenderedContentView: View {
    let id: UUID
    let content: String
    var componentStateJSON: String = ""
    /// 放在浅灰底的分组页面上（学习记录）。
    var grouped = false
    var onComponentState: (String, Any?) -> Void = { _, _ in }
    var onQuizResult: ([String: Any]) -> Void = { _ in }
    var onAsk: (String) -> Void = { _ in }

    @State private var height: CGFloat

    init(
        id: UUID,
        content: String,
        componentStateJSON: String = "",
        grouped: Bool = false,
        onComponentState: @escaping (String, Any?) -> Void = { _, _ in },
        onQuizResult: @escaping ([String: Any]) -> Void = { _ in },
        onAsk: @escaping (String) -> Void = { _ in }
    ) {
        self.id = id
        self.content = content
        self.componentStateJSON = componentStateJSON
        self.grouped = grouped
        self.onComponentState = onComponentState
        self.onQuizResult = onQuizResult
        self.onAsk = onAsk
        _height = State(initialValue: RenderCache.heights[id] ?? 60)
    }

    var body: some View {
        MessageWebView(
            messageID: id,
            content: content,
            isStreaming: false,
            componentStateJSON: componentStateJSON,
            height: $height,
            onComponentState: onComponentState,
            onAsk: onAsk,
            onQuizResult: onQuizResult,
            groupedSurface: grouped
        )
        .frame(height: height)
    }
}

enum MistakeFilter: String, CaseIterable, Identifiable {
    case due = "待复习"
    case all = "全部"
    case mastered = "已掌握"

    var id: String { rawValue }
}

struct MistakeBookView: View {
    @Environment(\.modelContext) private var context
    @Environment(ToastCenter.self) private var toasts
    @Query(sort: \Mistake.createdAt, order: .reverse) private var mistakes: [Mistake]
    @State private var filter = MistakeFilter.all
    @State private var subject: Subject?
    @State private var searchText = ""

    private var filtered: [Mistake] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        return mistakes.filter { mistake in
            if toasts.isHidden(mistake) { return false }
            switch filter {
            case .due: if !ReviewSchedule.isDue(mistake) { return false }
            case .mastered: if !mistake.isMastered { return false }
            case .all: break
            }
            if let subject, mistake.subject != subject { return false }
            guard !query.isEmpty else { return true }
            return mistake.previewText.localizedStandardContains(query)
                || mistake.topic.localizedStandardContains(query)
                || mistake.note.localizedStandardContains(query)
        }
    }

    private var dueCount: Int {
        mistakes.filter { !toasts.isHidden($0) && ReviewSchedule.isDue($0) }.count
    }

    /// 只列出已经有错题的科目。
    private var subjects: [Subject] {
        let present = Set(mistakes.compactMap(\.subject))
        return Subject.allCases.filter(present.contains)
    }

    var body: some View {
        List {
            Section {
                Picker("范围", selection: $filter) {
                    ForEach(MistakeFilter.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                if !subjects.isEmpty {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 8) {
                            SubjectChip(title: "全部科目", isSelected: subject == nil) { subject = nil }
                            ForEach(subjects) { item in
                                SubjectChip(title: item.rawValue, isSelected: subject == item) { subject = item }
                            }
                        }
                    }
                }
            }
            .listRowSeparator(.hidden)
            // 筛选放在灰底上，不放进白色卡片。
            .listRowBackground(Color.clear)
            .listRowInsets(EdgeInsets(top: Theme.Spacing.xs, leading: Theme.Spacing.l, bottom: Theme.Spacing.xs, trailing: Theme.Spacing.l))

            if dueCount > 0 {
                Section {
                    NavigationLink {
                        ReviewSessionView()
                    } label: {
                        Label("开始复习（今天 \(dueCount) 道）", systemImage: "play.circle.fill")
                            .font(.headline)
                    }
                }
            }

            Section {
                ForEach(filtered) { mistake in
                    NavigationLink {
                        MistakeDetailView(mistake: mistake)
                    } label: {
                        MistakeRow(mistake: mistake)
                    }
                }
                .onDelete { offsets in
                    let items = offsets.map { filtered[$0] }
                    toasts.delete(items, scope: .mistakes) { [context] in
                        items.forEach(context.delete)
                        try? context.save()
                    }
                }
            }
        }
        .listStyle(.insetGrouped)
        .toastBar(.mistakes)
        .overlay {
            if mistakes.allSatisfy({ toasts.isHidden($0) }) {
                OrbEmptyState(
                    title: "还没有错题",
                    message: "测验答错的题会自动加入，也可以长按自己的提问加入。"
                )
            } else if filtered.isEmpty {
                ContentUnavailableView("没有符合条件的错题", systemImage: "line.3.horizontal.decrease.circle")
            }
        }
        .searchable(text: $searchText, prompt: "搜索题目、知识点或备注")
        .navigationTitle("错题本")
    }
}

struct SubjectChip: View {
    let title: String
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.subheadline)
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(isSelected ? Color.accentColor : Color(.secondarySystemFill), in: Capsule())
                .foregroundStyle(isSelected ? Color.white : Color.primary)
        }
        .buttonStyle(.plain)
    }
}

private struct MistakeRow: View {
    let mistake: Mistake

    var body: some View {
        LibraryRow(
            title: mistake.previewText.isEmpty ? "（图片题）" : PlainTextExporter.previewText(from: mistake.previewText),
            subject: mistake.subject?.rawValue ?? "分类中…",
            meta: [mistake.topic, MistakeFormatting.status(mistake)].filter { !$0.isEmpty }.joined(separator: " · ")
        )
    }
}

enum MistakeFormatting {
    static func status(_ mistake: Mistake) -> String {
        if mistake.isMastered { return "已掌握" }
        if ReviewSchedule.isDue(mistake) { return "今天复习" }
        return "第 \(mistake.box + 1) 档 · \(mistake.dueAt.formatted(.dateTime.month().day())) 复习"
    }
}
