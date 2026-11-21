import CoreLocation
import Observation
import UIKit

/// "强力保活"要用的定位权限（见 docs/adr/0012）。
/// 在设置里打开开关时就请求权限，而不是等到生成汇编时才请求：
/// 那时用户往往已经准备切到别的 App，弹窗来不及点，后台定位就开不起来。
@MainActor
@Observable
final class LocationPermission: NSObject {
    static let shared = LocationPermission()

    enum Status {
        case notDetermined
        case granted
        case denied
    }

    private(set) var status: Status = .notDetermined

    private let manager = CLLocationManager()
    private var waiting: [CheckedContinuation<Status, Never>] = []

    override init() {
        super.init()
        manager.delegate = self
        status = Self.map(manager.authorizationStatus)
    }

    /// 还没决定时弹出系统的权限窗口并等用户选择；已经决定过时直接返回结果。
    func request() async -> Status {
        refresh()
        guard status == .notDetermined else { return status }
        return await withCheckedContinuation { continuation in
            waiting.append(continuation)
            manager.requestWhenInUseAuthorization()
        }
    }

    /// 从系统设置回来时重新读一次。
    func refresh() {
        status = Self.map(manager.authorizationStatus)
    }

    func openSystemSettings() {
        if let url = URL(string: UIApplication.openSettingsURLString) {
            UIApplication.shared.open(url)
        }
    }

    private static func map(_ status: CLAuthorizationStatus) -> Status {
        switch status {
        case .authorizedWhenInUse, .authorizedAlways: .granted
        case .denied, .restricted: .denied
        case .notDetermined: .notDetermined
        @unknown default: .denied
        }
    }

    fileprivate func authorizationChanged() {
        refresh()
        guard status != .notDetermined else { return }
        let continuations = waiting
        waiting.removeAll()
        continuations.forEach { $0.resume(returning: status) }
    }
}

extension LocationPermission: CLLocationManagerDelegate {
    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        Task { @MainActor in LocationPermission.shared.authorizationChanged() }
    }
}
