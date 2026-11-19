import Foundation

/// Leitner 分档复习：档位 0 到 4，对应间隔 1、3、7、14、30 天。
/// 答对升一档，答错回到第 0 档；在最高档再答对就算已掌握。
public enum ReviewSchedule {
    public static let intervals = [1, 3, 7, 14, 30]
    public static var topBox: Int { intervals.count - 1 }

    /// 第一次加入错题本，或者再次答错：回到第 0 档，明天复习。
    public static func reset(_ mistake: Mistake, now: Date = .now, calendar: Calendar = .current) {
        mistake.box = 0
        mistake.masteredAt = nil
        mistake.dueAt = dueDate(afterDays: intervals[0], from: now, calendar: calendar)
    }

    /// 复习一次之后更新档位。
    public static func record(_ mistake: Mistake, correct: Bool, now: Date = .now, calendar: Calendar = .current) {
        mistake.reviewCount += 1
        mistake.lastReviewedAt = now
        guard correct else {
            reset(mistake, now: now, calendar: calendar)
            return
        }
        if mistake.box >= topBox {
            mistake.masteredAt = now
            return
        }
        mistake.box += 1
        mistake.dueAt = dueDate(afterDays: intervals[mistake.box], from: now, calendar: calendar)
    }

    /// 已经到期的题（截至今天结束），掌握了的不算。
    public static func isDue(_ mistake: Mistake, now: Date = .now, calendar: Calendar = .current) -> Bool {
        !mistake.isMastered && mistake.dueAt <= endOfDay(now, calendar: calendar)
    }

    /// 到期日按天算：几天后的 0 点，这样当天任何时候打开都能复习。
    static func dueDate(afterDays days: Int, from now: Date, calendar: Calendar) -> Date {
        let start = calendar.startOfDay(for: now)
        return calendar.date(byAdding: .day, value: days, to: start) ?? now
    }

    static func endOfDay(_ date: Date, calendar: Calendar) -> Date {
        let start = calendar.startOfDay(for: date)
        return calendar.date(byAdding: DateComponents(day: 1, second: -1), to: start) ?? date
    }
}
