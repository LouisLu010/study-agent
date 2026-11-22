import SwiftUI

/// 汇编的调用记录：模型每调用一次工具一行，最新的在最下面（搜了什么、读了哪个网页、每道题取到了没有）。
/// 运行中最后一行带小球，顶上一行是"已搜索 N 次 · 用时"。默认只显示最近 6 行，可以展开全部。
struct CollectionActivityView: View {
    let compilationID: UUID
    let isRunning: Bool

    @Environment(CompilationCenter.self) private var center
    @State private var showsAll = false

    var body: some View {
        let lines = center.activity[compilationID] ?? []
        if !lines.isEmpty {
            VStack(alignment: .leading, spacing: Theme.Spacing.s) {
                HStack {
                    Text("调用记录")
                        .font(.subheadline.weight(.semibold))
                    Spacer()
                    if let stats = center.runStats[compilationID] {
                        TimelineView(.periodic(from: .now, by: 1)) { context in
                            Text("已搜索 \(stats.searches) 次 · " + Self.elapsed(from: stats.started, to: isRunning ? context.date : (lines.last?.time ?? context.date)))
                                .font(.caption.monospacedDigit())
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                let shown = showsAll ? lines : Array(lines.suffix(6))
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(shown.enumerated()), id: \.element.id) { index, line in
                        row(line, isLast: index == shown.count - 1)
                    }
                }
                .animation(.smooth(duration: 0.25), value: lines.count)
                if lines.count > 6 {
                    Button(showsAll ? "只看最近的" : "显示全部 \(lines.count) 步") { showsAll.toggle() }
                        .font(.caption)
                }
            }
            .padding(.vertical, Theme.Spacing.xs)
        }
    }

    private func row(_ line: CompilationCenter.ActivityLine, isLast: Bool) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: Theme.Spacing.s) {
            Group {
                if isLast && isRunning {
                    ActivityOrb(activity: line.kind == .search ? .searching : .background, size: 14)
                } else {
                    Image(systemName: icon(line.kind))
                        .foregroundStyle(color(line.kind))
                }
            }
            .font(.caption)
            .frame(width: 16)
            Text(line.text)
                .font(.footnote)
                .foregroundStyle(isLast ? .primary : .secondary)
                .lineLimit(2)
            Spacer(minLength: 0)
            Text(line.time.formatted(.dateTime.hour().minute().second()))
                .font(.caption2.monospacedDigit())
                .foregroundStyle(.tertiary)
        }
        .padding(.vertical, 3)
        .transition(.opacity.combined(with: .move(edge: .bottom)))
    }

    private func icon(_ kind: CompilationCenter.ActivityLine.Kind) -> String {
        switch kind {
        case .step: "arrow.right.circle"
        case .search: "magnifyingglass"
        case .page: "globe"
        case .success: "checkmark.circle.fill"
        case .warning: "exclamationmark.circle"
        }
    }

    private func color(_ kind: CompilationCenter.ActivityLine.Kind) -> Color {
        switch kind {
        case .success: Theme.success
        case .warning: .orange
        case .step: .accentColor
        default: .secondary
        }
    }

    static func elapsed(from start: Date, to end: Date) -> String {
        let seconds = max(0, Int(end.timeIntervalSince(start)))
        return String(format: "%d:%02d", seconds / 60, seconds % 60)
    }
}
