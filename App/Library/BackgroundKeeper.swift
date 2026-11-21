import BackgroundTasks
import CoreLocation
import Foundation
import UIKit

/// 跨并发域传递系统对象（BGTask 等）。只在主线程上使用里面的值。
struct UncheckedBox<Value>: @unchecked Sendable {
    let value: Value
}

/// 汇编在后台继续运行（见 docs/adr/0012）：
/// iOS 26 及以上用 `BGContinuedProcessingTask`，系统显示进度；
/// 打开"强力保活"时，生成期间开后台定位，iOS 18 到 25 也能在后台持续运行；
/// 都没有时，至少用 `beginBackgroundTask` 争取几十秒。
@MainActor
final class BackgroundKeeper: NSObject {
    static let shared = BackgroundKeeper()
    static let identifierPrefix = "com.louislu.studyagent.compilation"

    private var locationManager: CLLocationManager?
    private var continuedTask: AnyObject?
    private var legacyTask: UIBackgroundTaskIdentifier = .invalid
    private var onExpire: (() -> Void)?
    private var title = ""
    private var progress: (completed: Int, total: Int, subtitle: String) = (0, 1, "")
    private var isActive = false

    /// 开始一次汇编生成。`onExpire` 在系统要结束后台任务时调用，应该尽快停下并保存进度。
    func begin(title: String, onExpire: @escaping () -> Void) {
        end(success: false)
        isActive = true
        self.title = title
        self.onExpire = onExpire
        UIApplication.shared.isIdleTimerDisabled = true

        legacyTask = UIApplication.shared.beginBackgroundTask(withName: "汇编") { [weak self] in
            Task { @MainActor in self?.legacyExpired() }
        }
        if UserDefaults.standard.bool(forKey: AppSettingsKey.strongKeepAlive) {
            startLocation()
        }
        if #available(iOS 26.0, *) {
            submitContinuedTask()
        }
    }

    func update(completed: Int, total: Int, subtitle: String) {
        progress = (completed, max(total, 1), subtitle)
        if #available(iOS 26.0, *), let task = continuedTask as? BGContinuedProcessingTask {
            task.progress.totalUnitCount = Int64(progress.total)
            task.progress.completedUnitCount = Int64(min(completed, progress.total))
            task.updateTitle(title, subtitle: subtitle)
        }
    }

    func end(success: Bool) {
        guard isActive else { return }
        isActive = false
        onExpire = nil
        UIApplication.shared.isIdleTimerDisabled = false
        if #available(iOS 26.0, *), let task = continuedTask as? BGContinuedProcessingTask {
            task.setTaskCompleted(success: success)
        }
        continuedTask = nil
        stopLocation()
        if legacyTask != .invalid {
            UIApplication.shared.endBackgroundTask(legacyTask)
            legacyTask = .invalid
        }
    }

    // MARK: - BGContinuedProcessingTask

    @available(iOS 26.0, *)
    private func submitContinuedTask() {
        // 每次用新的标识符：同一个标识符注册两次会让 App 被系统结束。
        let identifier = "\(Self.identifierPrefix).\(UUID().uuidString)"
        let registered = BGTaskScheduler.shared.register(forTaskWithIdentifier: identifier, using: nil) { task in
            let box = UncheckedBox(value: task)
            Task { @MainActor in BackgroundKeeper.shared.attach(box.value) }
        }
        guard registered else { return }
        let request = BGContinuedProcessingTaskRequest(identifier: identifier, title: title, subtitle: "正在准备")
        request.strategy = .fail
        try? BGTaskScheduler.shared.submit(request)
    }

    @available(iOS 26.0, *)
    private func attach(_ task: BGTask) {
        guard let task = task as? BGContinuedProcessingTask else { return }
        guard isActive else {
            task.setTaskCompleted(success: true)
            return
        }
        continuedTask = task
        task.expirationHandler = {
            Task { @MainActor in BackgroundKeeper.shared.expired() }
        }
        update(completed: progress.completed, total: progress.total, subtitle: progress.subtitle)
    }

    private func expired() {
        let handler = onExpire
        end(success: false)
        handler?()
    }

    private func legacyExpired() {
        if legacyTask != .invalid {
            UIApplication.shared.endBackgroundTask(legacyTask)
            legacyTask = .invalid
        }
        // 有系统长任务或定位保活时还能继续；都没有就要停下保存进度。
        if continuedTask == nil && locationManager == nil {
            expired()
        }
    }

    // MARK: - 定位保活

    private func startLocation() {
        let manager = CLLocationManager()
        manager.delegate = self
        // 精度太低时 iOS 可能照样把 App 挂起，用 100 米一档。
        manager.desiredAccuracy = kCLLocationAccuracyHundredMeters
        manager.distanceFilter = kCLDistanceFilterNone
        manager.pausesLocationUpdatesAutomatically = false
        manager.showsBackgroundLocationIndicator = true
        if manager.authorizationStatus == .notDetermined {
            manager.requestWhenInUseAuthorization()
        }
        manager.allowsBackgroundLocationUpdates = true
        manager.startUpdatingLocation()
        locationManager = manager
    }

    private func stopLocation() {
        locationManager?.stopUpdatingLocation()
        locationManager?.allowsBackgroundLocationUpdates = false
        locationManager = nil
    }
}

extension BackgroundKeeper: CLLocationManagerDelegate {
    // 位置本身不用，不保存也不发送。
    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {}
    nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError error: any Error) {}
}
