import Foundation
import StudyKit
import SwiftData
import UserNotifications

/// 复习提醒：每天在设定的时间提醒一次，只在那天有到期的错题时才提醒。
/// 本地通知没法在触发时再去数题目，所以提前排好未来 7 天的通知，每次打开 App、复习完都重新排一遍。
@MainActor
enum ReviewReminder {
    static let enabledKey = "reviewReminderEnabled"
    /// 提醒时间，从 0 点开始的分钟数。默认 20:00。
    static let minutesKey = "reviewReminderMinutes"
    static let defaultMinutes = 20 * 60
    private static let identifierPrefix = "review-"
    private static let daysAhead = 7

    static var isEnabled: Bool { UserDefaults.standard.bool(forKey: enabledKey) }

    static var minutes: Int {
        UserDefaults.standard.object(forKey: minutesKey) as? Int ?? defaultMinutes
    }

    /// 打开提醒时请求通知权限。用户拒绝时返回 false。
    static func requestPermission() async -> Bool {
        (try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge])) ?? false
    }

    static func reschedule(in context: ModelContext) {
        let mistakes = (try? context.fetch(FetchDescriptor<Mistake>(predicate: #Predicate { $0.masteredAt == nil }))) ?? []
        let dueDates = mistakes.map(\.dueAt)
        let enabled = isEnabled
        let minutes = minutes
        Task {
            let center = UNUserNotificationCenter.current()
            let pending = await center.pendingNotificationRequests()
            center.removePendingNotificationRequests(withIdentifiers: pending.map(\.identifier).filter { $0.hasPrefix(identifierPrefix) })
            guard enabled else { return }

            let calendar = Calendar.current
            let now = Date()
            for offset in 0..<daysAhead {
                guard let day = calendar.date(byAdding: .day, value: offset, to: calendar.startOfDay(for: now)),
                      let fireDate = calendar.date(byAdding: .minute, value: minutes, to: day),
                      fireDate > now
                else { continue }
                // 假设这期间不复习，那天到期的题数。
                let endOfDay = calendar.date(byAdding: DateComponents(day: 1, second: -1), to: day) ?? day
                let count = dueDates.filter { $0 <= endOfDay }.count
                guard count > 0 else { continue }

                let content = UNMutableNotificationContent()
                content.title = "该复习了"
                content.body = "错题本里有 \(count) 道题待复习。"
                content.sound = .default
                let components = calendar.dateComponents([.year, .month, .day, .hour, .minute], from: fireDate)
                let request = UNNotificationRequest(
                    identifier: identifierPrefix + "\(offset)",
                    content: content,
                    trigger: UNCalendarNotificationTrigger(dateMatching: components, repeats: false)
                )
                try? await center.add(request)
            }
        }
    }
}
