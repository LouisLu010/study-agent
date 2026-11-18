import Foundation
import Testing
@testable import StudyKit

@Suite struct ReviewScheduleTests {
    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Shanghai")!
        return calendar
    }

    private func date(_ day: Int, _ hour: Int = 20) -> Date {
        calendar.date(from: DateComponents(year: 2026, month: 11, day: day, hour: hour))!
    }

    @Test func climbsBoxesAndMasters() {
        let mistake = Mistake(kind: .quiz)
        ReviewSchedule.reset(mistake, now: date(1), calendar: calendar)
        #expect(mistake.box == 0)
        #expect(mistake.dueAt == calendar.startOfDay(for: date(2)))
        #expect(!ReviewSchedule.isDue(mistake, now: date(1, 23), calendar: calendar))
        #expect(ReviewSchedule.isDue(mistake, now: date(2, 0), calendar: calendar))

        let expectedDays = [3, 7, 14, 30]
        for (step, days) in expectedDays.enumerated() {
            ReviewSchedule.record(mistake, correct: true, now: date(2), calendar: calendar)
            #expect(mistake.box == step + 1)
            #expect(mistake.dueAt == calendar.date(byAdding: .day, value: days, to: calendar.startOfDay(for: date(2))))
        }
        ReviewSchedule.record(mistake, correct: true, now: date(3), calendar: calendar)
        #expect(mistake.isMastered)
        #expect(!ReviewSchedule.isDue(mistake, now: date(30), calendar: calendar))
        #expect(mistake.reviewCount == 5)
    }

    @Test func wrongAnswerResets() {
        let mistake = Mistake(kind: .manual)
        mistake.box = 3
        ReviewSchedule.record(mistake, correct: false, now: date(5), calendar: calendar)
        #expect(mistake.box == 0)
        #expect(mistake.dueAt == calendar.startOfDay(for: date(6)))
    }
}

@Suite struct MistakeTests {
    @Test func dedupeKeyIgnoresExplanationAndWhitespace() {
        let a = #"{"type":"choice","question":"1+1=?","options":["1","2"],"answer":"B","explanation":"x"}"#
        let b = #"{"type":"choice","question":" 1+1=? ","options":["1","2"],"answer":"B"}"#
        let c = #"{"type":"choice","question":"1+1=?","options":["2","3"],"answer":"A"}"#
        #expect(Mistake.dedupeKey(forQuestionJSON: a) == Mistake.dedupeKey(forQuestionJSON: b))
        #expect(Mistake.dedupeKey(forQuestionJSON: a) != Mistake.dedupeKey(forQuestionJSON: c))
    }

    @Test func previewAndMarkdown() {
        let mistake = Mistake(kind: .quiz)
        mistake.questionJSON = #"{"type":"number","question":"$\\int_0^1 x\\,dx$","answer":0.5}"#
        #expect(mistake.previewText == #"$\int_0^1 x\,dx$"#)
        #expect(mistake.quizMarkdown.hasPrefix("```quiz\n{\"questions\":[{"))
    }

    @Test func normalizesSubjects() {
        #expect(Subject.normalize("高中物理") == .physics)
        #expect(Subject.normalize("Chemistry") == .chemistry)
        #expect(Subject.normalize("历史") == .other)
        #expect(Subject.normalize("  ") == nil)
    }
}

@Suite struct SubjectClassifierTests {
    @Test func parsesModelOutput() {
        let result = SubjectClassifier.parse("```json\n{\"subject\": \"物理\", \"topic\": \"平抛运动\"}\n```")
        #expect(result?.subject == .physics)
        #expect(result?.topic == "平抛运动")
        #expect(SubjectClassifier.parse("我不知道") == nil)
        #expect(SubjectClassifier.parse(#"{"subject":"","topic":"x"}"#) == nil)
    }
}

@Suite struct StudyStatsTests {
    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Shanghai")!
        return calendar
    }

    private func day(_ d: Int, _ h: Int = 12) -> Date {
        calendar.date(from: DateComponents(year: 2026, month: 11, day: d, hour: h))!
    }

    @Test func dailyCountsIncludeEmptyDays() {
        let events = [
            StudyEvent(kind: .quiz, correct: true, subject: "数学", topic: "", date: day(20, 9)),
            StudyEvent(kind: .review, correct: false, subject: "数学", topic: "", date: day(20, 21)),
            StudyEvent(kind: .quiz, correct: true, subject: "物理", topic: "", date: day(18)),
            StudyEvent(kind: .quiz, correct: true, subject: "物理", topic: "", date: day(1)),
        ]
        let daily = StudyStats.daily(events, days: 5, now: day(20), calendar: calendar)
        #expect(daily.count == 5)
        #expect(daily.map(\.answered) == [0, 0, 1, 0, 2])
        #expect(daily.last?.correct == 1)
    }

    @Test func subjectsAndWeakTopics() {
        func mistake(_ subject: Subject, _ topic: String, mastered: Bool = false) -> Mistake {
            let m = Mistake(kind: .quiz)
            m.subject = subject
            m.topic = topic
            if mastered { m.masteredAt = .now }
            return m
        }
        let mistakes = [
            mistake(.math, "导数"), mistake(.math, "导数"), mistake(.math, "数列", mastered: true),
            mistake(.physics, "平抛运动"), mistake(.physics, "未分类"),
        ]
        #expect(StudyStats.bySubject(mistakes) == [
            .init(subject: .math, total: 3, mastered: 1),
            .init(subject: .physics, total: 2, mastered: 0),
        ])
        let weak = StudyStats.weakestTopics(mistakes)
        #expect(weak.map(\.topic) == ["数学 · 导数", "物理 · 平抛运动"])
        #expect(weak.first?.count == 2)
    }

    @Test func buildsChartMarkdown() {
        let chart = StudyStats.topicChart([("数学 · 导数", 2)])
        #expect(chart.hasPrefix("```chart\n{"))
        #expect(chart.contains("\"type\":\"bar\""))
    }
}
