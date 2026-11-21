import SwiftUI

/// 汇编运行时的一行状态：现在切到别的 App 能不能继续。不能时说明原因，并给一个"打开强力保活"按钮。
struct BackgroundStatusRow: View {
    @State private var keeper = BackgroundKeeper.shared
    @State private var location = LocationPermission.shared
    @State private var isEnabling = false
    @State private var denied = false

    var body: some View {
        if keeper.locationActive {
            Label("强力保活中，可以切到别的 App", systemImage: "location.fill")
                .font(.callout)
                .foregroundStyle(.secondary)
        } else if keeper.systemTask == .running {
            Label("系统允许在后台继续，可以切到别的 App", systemImage: "checkmark.circle")
                .font(.callout)
                .foregroundStyle(.secondary)
        } else if keeper.systemTask == .waiting || keeper.systemTask == .idle {
            EmptyView()
        } else {
            VStack(alignment: .leading, spacing: Theme.Spacing.s) {
                Label {
                    Text(reason + "切到别的 App 约 30 秒后会暂停，回来后自动继续。打开强力保活就能一直在后台运行。")
                } icon: {
                    Image(systemName: "exclamationmark.triangle")
                }
                .font(.callout)
                .foregroundStyle(.orange)
                if denied || location.status == .denied {
                    Button("定位权限被关闭了，去系统设置打开") { location.openSystemSettings() }
                        .font(.callout)
                } else {
                    Button(isEnabling ? "正在请求定位权限…" : "打开强力保活") {
                        isEnabling = true
                        Task {
                            denied = !(await keeper.enableStrongKeepAlive())
                            isEnabling = false
                        }
                    }
                    .font(.callout.weight(.semibold))
                    .disabled(isEnabling)
                }
            }
        }
    }

    private var reason: String {
        switch keeper.systemTask {
        case let .refused(text): text + "。"
        case .unsupported: "这个系统版本没有后台长任务。"
        default: ""
        }
    }
}
