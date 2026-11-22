import SwiftUI

/// 要全屏显示的一个组件：它在原消息里的组件键、只有这个组件的 Markdown、打开时的状态（JSON）。
struct FullscreenComponent: Identifiable {
    let id = UUID()
    let key: String
    let markdown: String
    let stateJSON: String
}

/// 模拟、坐标图、几何图的全屏页（第八版）：单独用一个 WebView 只显示这一个组件，画面更大，
/// 竖屏时参数面板在下方，横屏时在侧边。打开时带上当前的组件状态，改动随时写回原消息，关掉后正文里的组件按新状态重画。
struct ComponentFullscreenView: View {
    let request: FullscreenComponent
    /// 组件状态变化（nil 表示复位），写回原消息里这个组件的键。
    let onState: (Any?) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var height: CGFloat = 480

    var body: some View {
        NavigationStack {
            ScrollView {
                MessageWebView(
                    messageID: request.id,
                    content: request.markdown,
                    isStreaming: false,
                    // 全屏页里只有这一个组件，它的键是 c0。
                    componentStateJSON: request.stateJSON.isEmpty ? "" : "{\"c0\":\(request.stateJSON)}",
                    height: $height,
                    onComponentState: { _, state in onState(state) },
                    fullscreenSurface: true
                )
                .frame(height: height)
                .padding(.horizontal, Theme.Spacing.l)
                .padding(.vertical, Theme.Spacing.s)
            }
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") { dismiss() }
                }
            }
        }
    }
}
