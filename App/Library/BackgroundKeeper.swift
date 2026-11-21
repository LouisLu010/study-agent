import BackgroundTasks
import CoreLocation
import Foundation
import Observation
import UIKit

/// 汇编在后台继续运行（见 docs/adr/0012）：
/// iOS 26 及以上用 `BGContinuedProcessingTask`，系统显示进度；
/// 打开"强力保活"时，生成期间开后台定位，iOS 18 到 25 也能在后台持续运行；
/// 都没有时，至少用 `beginBackgroundTask` 争取几十秒。
///
/// 查找试卷、逐份查题、重新获取一道题、写 AI 解析都算一项"工作"，可以同时有好几项。
/// 第一项开始时申请后台运行，最后一项结束时释放。系统进度显示最近开始的那一项。
@MainActor
@Observable
final class BackgroundKeeper: NSObject {
    static let shared = BackgroundKeeper()

    /// 系统长任务的标识符。按运行时的 Bundle ID 拼，只注册一次、之后重复提交：
    /// 同一个标识符注册两次会让 App 被系统结束，而每次用新的标识符要靠 Info.plist 里的通配符匹配，
    /// 自签安装时不一定可靠。Info.plist 里同时登记了这个固定的标识符和 compilation.* 通配符。
    static var taskIdentifier: String {
        (Bundle.main.bundleIdentifier ?? "com.louislu.studyagent") + ".compilation.run"
    }
    private static var registered: Bool?

    /// 系统长任务（iOS 26 的 BGContinuedProcessingTask）这一次有没有批下来。
    enum SystemTask: Equatable {
        /// 没有在跑的工作。
        case idle
        /// iOS 26 以下没有这个接口。
        case unsupported
        /// 已经提交，等系统答复。
        case waiting
        /// 系统批了，切到别的 App 也会继续。
        case running
        /// 没批下来，原因给用户看。
        case refused(String)
    }

    private(set) var systemTask = SystemTask.idle
    /// 强力保活的后台定位正在运行。
    private(set) var locationActive = false

    /// 现在切到别的 App 能不能继续运行。
    var isProtected: Bool { locationActive || systemTask == .running }

    private struct Job {
        var title: String
        var completed = 0
        var total = 1
        var subtitle: String
        var onExpire: () -> Void
    }

    @ObservationIgnored private var jobs: [UUID: Job] = [:]
    /// 开始的先后顺序，最后一个显示在系统进度里。
    @ObservationIgnored private var order: [UUID] = []
    /// 当前这一步里收到的流式事件数，用来让进度条在一次长请求中也慢慢往前走。
    /// 系统会结束长时间没有进度的 BGContinuedProcessingTask。
    @ObservationIgnored private var ticks = 0

    @ObservationIgnored private var locationManager: CLLocationManager?
    @ObservationIgnored private var continuedTask: AnyObject?
    @ObservationIgnored private var legacyTask: UIBackgroundTaskIdentifier = .invalid

    /// App 最近一次进入后台的时间。用来判断一次网络错误是不是因为切到了别的 App。
    @ObservationIgnored private(set) var lastEnteredBackground: Date?

    override init() {
        super.init()
        NotificationCenter.default.addObserver(
            forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: .main
        ) { _ in
            MainActor.assumeIsolated { BackgroundKeeper.shared.lastEnteredBackground = .now }
        }
    }

    /// 开始一项工作。`onExpire` 在系统要结束后台运行时调用，应该尽快停下并保存进度。
    func begin(id: UUID, title: String, subtitle: String = "正在准备", onExpire: @escaping () -> Void = {}) {
        let first = jobs.isEmpty
        jobs[id] = Job(title: title, subtitle: subtitle, onExpire: onExpire)
        order.removeAll { $0 == id }
        order.append(id)
        ticks = 0
        if first {
            startKeepAlive(title: title, subtitle: subtitle)
        } else {
            refresh()
        }
    }

    func update(id: UUID, completed: Int, total: Int, subtitle: String) {
        guard var job = jobs[id] else { return }
        job.completed = completed
        job.total = max(total, 1)
        job.subtitle = subtitle
        jobs[id] = job
        ticks = 0
        refresh()
    }

    /// 收到一个流式事件：一步之内进度最多往前走 90%，下一次 update 时归零。
    func tick() {
        guard !jobs.isEmpty, ticks < 90 else { return }
        ticks += 1
        refreshProgress()
    }

    func end(id: UUID, success: Bool) {
        guard jobs.removeValue(forKey: id) != nil else { return }
        order.removeAll { $0 == id }
        if jobs.isEmpty {
            stopKeepAlive(success: success)
        } else {
            refresh()
        }
    }

    // MARK: - 申请和释放

    private func startKeepAlive(title: String, subtitle: String) {
        UIApplication.shared.isIdleTimerDisabled = true
        legacyTask = UIApplication.shared.beginBackgroundTask(withName: "汇编") { [weak self] in
            Task { @MainActor in self?.legacyExpired() }
        }
        if UserDefaults.standard.bool(forKey: AppSettingsKey.strongKeepAlive) {
            LocationPermission.shared.refresh()
            if LocationPermission.shared.status == .granted {
                startLocation()
            } else {
                // 开关开着但没有权限（例如旧版本打开的开关）：现在补请求，下次生成就能用。
                Task { _ = await LocationPermission.shared.request() }
            }
        }
        if #available(iOS 26.0, *) {
            submitContinuedTask(title: title, subtitle: subtitle)
        } else {
            systemTask = .unsupported
        }
    }

    /// 在汇编页面上点"打开强力保活"：请求定位权限，拿到了就打开设置并立刻开始后台定位。
    func enableStrongKeepAlive() async -> Bool {
        guard await LocationPermission.shared.request() == .granted else { return false }
        UserDefaults.standard.set(true, forKey: AppSettingsKey.strongKeepAlive)
        if !jobs.isEmpty && locationManager == nil { startLocation() }
        return true
    }

    private func stopKeepAlive(success: Bool) {
        UIApplication.shared.isIdleTimerDisabled = false
        if #available(iOS 26.0, *), let task = continuedTask as? BGContinuedProcessingTask {
            task.setTaskCompleted(success: success)
        }
        continuedTask = nil
        systemTask = .idle
        stopLocation()
        if legacyTask != .invalid {
            UIApplication.shared.endBackgroundTask(legacyTask)
            legacyTask = .invalid
        }
    }

    private var current: Job? {
        order.last.flatMap { jobs[$0] }
    }

    private func refresh() {
        refreshProgress()
        if #available(iOS 26.0, *), let task = continuedTask as? BGContinuedProcessingTask, let job = current {
            task.updateTitle(job.title, subtitle: job.subtitle)
        }
    }

    private func refreshProgress() {
        guard #available(iOS 26.0, *), let task = continuedTask as? BGContinuedProcessingTask, let job = current else { return }
        // 每一步分成 100 份：已完成的步数 × 100，加上这一步里收到的事件数。
        task.progress.totalUnitCount = Int64(job.total * 100)
        task.progress.completedUnitCount = Int64(min(job.completed, job.total) * 100 + min(ticks, 90))
    }

    // MARK: - BGContinuedProcessingTask

    @available(iOS 26.0, *)
    private func submitContinuedTask(title: String, subtitle: String) {
        let identifier = Self.taskIdentifier
        if Self.registered == nil {
            Self.registered = register(identifier)
        }
        guard Self.registered == true else {
            // 注册失败只有一个原因：Info.plist 里没有这个标识符。自签工具改了 Bundle ID 时就会这样。
            systemTask = .refused("安装时 Bundle ID 被改成了 \(Bundle.main.bundleIdentifier ?? "?")，系统不认这个 App 登记的后台任务")
            return
        }
        systemTask = .waiting
        let request = BGContinuedProcessingTaskRequest(identifier: identifier, title: title, subtitle: subtitle)
        request.strategy = .fail
        do {
            try BGTaskScheduler.shared.submit(request)
        } catch {
            systemTask = .refused("系统拒绝了后台任务：\(error.localizedDescription)")
            return
        }
        // 系统批了会在一瞬间回调；几秒都没有回调就是没批（自签安装时常见，系统不报错）。
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(4))
            guard let self, self.systemTask == .waiting, !self.jobs.isEmpty else { return }
            self.systemTask = .refused("系统没有启动后台任务，自签安装的 App 常遇到")
        }
    }

    @available(iOS 26.0, *)
    private func register(_ identifier: String) -> Bool {
        // 必须用 .main：这个闭包写在 @MainActor 的类里，Swift 6 会把它当成只能在主线程运行，
        // 进入时检查当前线程。传 nil 时系统在后台队列上调用它，检查不通过，App 直接闪退
        // （_dispatch_assert_queue_fail）。编译器对这种情况不报警告。
        BGTaskScheduler.shared.register(forTaskWithIdentifier: identifier, using: .main) { task in
            BackgroundKeeper.shared.attach(task)
        }
    }

    @available(iOS 26.0, *)
    private func attach(_ task: BGTask) {
        guard let task = task as? BGContinuedProcessingTask else { return }
        guard !jobs.isEmpty, continuedTask == nil else {
            task.setTaskCompleted(success: true)
            return
        }
        continuedTask = task
        systemTask = .running
        task.expirationHandler = Self.expirationHandler()
        refresh()
    }

    /// 到期回调可能在任意线程上调用，所以在 nonisolated 的地方创建，不带主线程检查，再切回主线程。
    nonisolated private static func expirationHandler() -> @Sendable () -> Void {
        { Task { @MainActor in BackgroundKeeper.shared.expired() } }
    }

    /// 系统要结束后台运行：通知所有工作停下保存进度。
    private func expired() {
        let handlers = order.compactMap { jobs[$0]?.onExpire }
        jobs.removeAll()
        order.removeAll()
        stopKeepAlive(success: false)
        handlers.forEach { $0() }
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
        manager.allowsBackgroundLocationUpdates = true
        manager.startUpdatingLocation()
        locationManager = manager
        locationActive = true
    }

    private func stopLocation() {
        locationManager?.stopUpdatingLocation()
        locationManager?.allowsBackgroundLocationUpdates = false
        locationManager = nil
        locationActive = false
    }
}

extension BackgroundKeeper: CLLocationManagerDelegate {
    // 位置本身不用，不保存也不发送。
    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {}
    nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError error: any Error) {}
}
