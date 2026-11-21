import StudyKit
import SwiftData
import SwiftUI

/// 学习记录：三张图，用渲染器里的图表组件显示。
struct StudyStatsView: View {
    @Query private var events: [StudyEvent]
    @Query private var mistakes: [Mistake]

    private var daily: [StudyStats.DailyCount] { StudyStats.daily(events) }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                summary

                if events.isEmpty && mistakes.isEmpty {
                    OrbEmptyState(title: "还没有学习记录", message: "在会话里做测验、复习错题之后，这里会显示统计。")
                } else {
                    // 图表的内容随数据变化，用内容的哈希区分 WebView，数据变了就重新渲染。
                    chart(StudyStats.dailyChart(daily))
                    let subjects = StudyStats.bySubject(mistakes)
                    if !subjects.isEmpty {
                        chart(StudyStats.subjectChart(subjects))
                    }
                    let topics = StudyStats.weakestTopics(mistakes)
                    if !topics.isEmpty {
                        chart(StudyStats.topicChart(topics))
                    }
                }
            }
            .padding()
            .frame(maxWidth: 820)
            .frame(maxWidth: .infinity)
        }
        .navigationTitle("学习记录")
    }

    private var summary: some View {
        let last30 = daily.reduce(0) { $0 + $1.answered }
        let correct = daily.reduce(0) { $0 + $1.correct }
        let mastered = mistakes.filter(\.isMastered).count
        return HStack(spacing: 12) {
            StatTile(title: "30 天答题", value: "\(last30)")
            StatTile(title: "正确率", value: last30 > 0 ? "\(Int((Double(correct) / Double(last30) * 100).rounded()))%" : "—")
            StatTile(title: "已掌握错题", value: "\(mastered) / \(mistakes.count)")
        }
    }

    private func chart(_ markdown: String) -> some View {
        RenderedContentView(id: StatsChartID.id(for: markdown), content: markdown)
            .id(markdown)
    }
}

private struct StatTile: View {
    let title: String
    let value: String

    var body: some View {
        VStack(spacing: 4) {
            Text(value).font(.title2.bold()).monospacedDigit()
            Text(title).font(.caption).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, Theme.Spacing.m)
        .cardBackground()
    }
}

/// 每段图表内容对应一个固定的 id，用于高度缓存。
@MainActor
private enum StatsChartID {
    static var ids: [String: UUID] = [:]

    static func id(for markdown: String) -> UUID {
        if let id = ids[markdown] { return id }
        let id = UUID()
        ids[markdown] = id
        return id
    }
}
