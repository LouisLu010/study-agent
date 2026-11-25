import StudyKit
import SwiftData
import SwiftUI
import UIKit

/// 长按 App 图标弹出的快捷菜单（第九版）：新会话、拍题、开始复习。
/// 菜单项在退到后台时按当前状态重新设置：没有到期的错题时不放"开始复习"。
enum QuickAction: String {
    case newChat = "com.louislu.studyagent.newChat"
    case snapQuestion = "com.louislu.studyagent.snapQuestion"
    case review = "com.louislu.studyagent.review"

    @MainActor
    var shortcutItem: UIApplicationShortcutItem {
        switch self {
        case .newChat:
            UIApplicationShortcutItem(type: rawValue, localizedTitle: "新会话", localizedSubtitle: nil,
                                      icon: UIApplicationShortcutIcon(systemImageName: "square.and.pencil"))
        case .snapQuestion:
            UIApplicationShortcutItem(type: rawValue, localizedTitle: "拍题", localizedSubtitle: nil,
                                      icon: UIApplicationShortcutIcon(systemImageName: "camera"))
        case .review:
            UIApplicationShortcutItem(type: rawValue, localizedTitle: "开始复习", localizedSubtitle: nil,
                                      icon: UIApplicationShortcutIcon(systemImageName: "arrow.counterclockwise.circle"))
        }
    }

    /// 按当前状态设置图标上的快捷菜单。
    @MainActor
    static func updateShortcutItems(in context: ModelContext) {
        var actions: [QuickAction] = [.newChat]
        if CameraPicker.isAvailable { actions.append(.snapQuestion) }
        let active = (try? context.fetch(FetchDescriptor<Mistake>(predicate: #Predicate { $0.masteredAt == nil }))) ?? []
        if active.contains(where: { ReviewSchedule.isDue($0) }) { actions.append(.review) }
        UIApplication.shared.shortcutItems = actions.map(\.shortcutItem)
    }
}

/// 系统把快捷菜单的选择交给场景代理，场景代理放在这里，RootView 取走后处理。
@MainActor
@Observable
final class QuickActionInbox {
    static let shared = QuickActionInbox()
    var pending: QuickAction?
}

/// 只为了接快捷菜单：SwiftUI 的 App 生命周期没有直接的入口，要通过场景代理拿到。
final class AppDelegate: NSObject, UIApplicationDelegate {
    func application(
        _ application: UIApplication,
        configurationForConnecting connectingSceneSession: UISceneSession,
        options: UIScene.ConnectionOptions
    ) -> UISceneConfiguration {
        let configuration = UISceneConfiguration(name: nil, sessionRole: connectingSceneSession.role)
        configuration.delegateClass = QuickActionSceneDelegate.self
        return configuration
    }
}

final class QuickActionSceneDelegate: NSObject, UIWindowSceneDelegate {
    /// App 没在运行时点了快捷菜单：选择在启动参数里。
    func scene(_ scene: UIScene, willConnectTo session: UISceneSession, options connectionOptions: UIScene.ConnectionOptions) {
        guard let item = connectionOptions.shortcutItem else { return }
        receive(item)
    }

    /// App 已经在后台时点了快捷菜单。
    func windowScene(
        _ windowScene: UIWindowScene,
        performActionFor shortcutItem: UIApplicationShortcutItem,
        completionHandler: @escaping (Bool) -> Void
    ) {
        completionHandler(receive(shortcutItem))
    }

    @discardableResult
    private func receive(_ item: UIApplicationShortcutItem) -> Bool {
        guard let action = QuickAction(rawValue: item.type) else { return false }
        MainActor.assumeIsolated { QuickActionInbox.shared.pending = action }
        return true
    }
}
