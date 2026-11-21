import SwiftUI

/// 空页面：大号小球做主图，下面是标题、说明和按钮。代替系统的 ContentUnavailableView 加图标。
struct OrbEmptyState<Actions: View>: View {
    let title: String
    var message: String?
    var orbSize: CGFloat = 88
    @ViewBuilder var actions: Actions

    var body: some View {
        VStack(spacing: Theme.Spacing.l) {
            ActivityOrb(activity: .idle, size: orbSize)
                .padding(.bottom, Theme.Spacing.xs)
            VStack(spacing: Theme.Spacing.s) {
                Text(title)
                    .font(.title3.bold())
                if let message {
                    Text(message)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }
            .multilineTextAlignment(.center)
            actions
        }
        .padding(Theme.Spacing.xl)
        .frame(maxWidth: 440)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

extension OrbEmptyState where Actions == EmptyView {
    init(title: String, message: String? = nil, orbSize: CGFloat = 88) {
        self.init(title: title, message: message, orbSize: orbSize) { EmptyView() }
    }
}
