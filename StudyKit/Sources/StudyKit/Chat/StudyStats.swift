import Foundation

/// 学习记录的统计，结果直接拼成图表组件的 JSON，用现有的图表组件显示。
public enum StudyStats {
    public struct DailyCount: Equatable {
        public var day: Date
        public var answered: Int
        public var correct: Int
    }

    /// 最近 days 天（含今天）每天的作答数和答对数，没有记录的日子也列出来，数量为 0。
    public static func daily(
        _ events: [StudyEvent],
        days: Int = 30,
        now: Date = .now,
        calendar: Calendar = .current
    ) -> [DailyCount] {
        let today = calendar.startOfDay(for: now)
        var buckets: [Date: (Int, Int)] = [:]
        for event in events {
            let day = calendar.startOfDay(for: event.date)
            var value = buckets[day] ?? (0, 0)
            value.0 += 1
            if event.correct { value.1 += 1 }
            buckets[day] = value
        }
        return (0..<days).reversed().compactMap { offset in
            guard let day = calendar.date(byAdding: .day, value: -offset, to: today) else { return nil }
            let value = buckets[day] ?? (0, 0)
            return DailyCount(day: day, answered: value.0, correct: value.1)
        }
    }

    /// 连续学习天数（见 GLOSSARY「连续学习天数」）：到今天为止，每天都至少做过一次测验或复习的连续天数。
    /// 今天还没做题时按截至昨天计算，早上打开不会先看到 0。传入每次作答的时间。
    public static func streak(_ dates: [Date], now: Date = .now, calendar: Calendar = .current) -> Int {
        let days = Set(dates.map { calendar.startOfDay(for: $0) })
        let today = calendar.startOfDay(for: now)
        guard var day = days.contains(today) ? today : calendar.date(byAdding: .day, value: -1, to: today) else { return 0 }
        var count = 0
        while days.contains(day) {
            count += 1
            guard let previous = calendar.date(byAdding: .day, value: -1, to: day) else { break }
            day = previous
        }
        return count
    }

    public struct SubjectCount: Equatable {
        public var subject: Subject
        public var total: Int
        public var mastered: Int
    }

    public static func bySubject(_ mistakes: [Mistake]) -> [SubjectCount] {
        Subject.allCases.compactMap { subject in
            let items = mistakes.filter { $0.subject == subject }
            guard !items.isEmpty else { return nil }
            return SubjectCount(subject: subject, total: items.count, mastered: items.filter(\.isMastered).count)
        }
    }

    /// 错得最多的知识点：按还没掌握的错题数排序。
    public static func weakestTopics(_ mistakes: [Mistake], limit: Int = 5) -> [(topic: String, count: Int)] {
        var counts: [String: Int] = [:]
        for mistake in mistakes where !mistake.isMastered {
            let topic = mistake.topic.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !topic.isEmpty, topic != "未分类" else { continue }
            let key = [mistake.subject?.rawValue, topic].compactMap { $0 }.joined(separator: " · ")
            counts[key, default: 0] += 1
        }
        return counts.sorted { $0.value != $1.value ? $0.value > $1.value : $0.key < $1.key }
            .prefix(limit)
            .map { ($0.key, $0.value) }
    }

    // MARK: - 图表组件

    public static func dailyChart(_ daily: [DailyCount], calendar: Calendar = .current) -> String {
        let labels = daily.map { "\(calendar.component(.month, from: $0.day))/\(calendar.component(.day, from: $0.day))" }
        return chart([
            "type": "bar",
            "title": "最近 \(daily.count) 天的答题数",
            "labels": labels,
            "datasets": [
                ["label": "答对", "data": daily.map(\.correct)],
                ["label": "答错", "data": daily.map { $0.answered - $0.correct }],
            ],
            "stacked": true,
            "unit": "道",
        ])
    }

    public static func subjectChart(_ counts: [SubjectCount]) -> String {
        chart([
            "type": "bar",
            "title": "各科目错题",
            "labels": counts.map(\.subject.rawValue),
            "datasets": [
                ["label": "已掌握", "data": counts.map(\.mastered)],
                ["label": "未掌握", "data": counts.map { $0.total - $0.mastered }],
            ],
            "stacked": true,
            "unit": "道",
        ])
    }

    public static func topicChart(_ topics: [(topic: String, count: Int)]) -> String {
        chart([
            "type": "bar",
            "title": "错得最多的知识点",
            "labels": topics.map(\.topic),
            "datasets": [["label": "未掌握的错题", "data": topics.map(\.count)]],
            "unit": "道",
        ])
    }

    static func chart(_ spec: [String: Any]) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: spec, options: [.sortedKeys]) else { return "" }
        return "```chart\n" + String(decoding: data, as: UTF8.self) + "\n```"
    }
}
