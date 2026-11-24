import SwiftData
import SwiftUI

/// 底部提示条（第九版）：删除后的"撤销"，以及"已加入错题本 · 写备注"这类带一个按钮的提示。
///
/// 删除不立即执行：先把这些对象藏起来，提示条显示 5 秒，没撤销才真正删掉。
/// 5 秒内 App 被关掉的话什么都没删，对象下次还在，宁可留着也不误删。
@MainActor
@Observable
final class ToastCenter {
    /// 提示条显示在哪个页面。iPad 上侧栏和右边同时显示，只在发起操作的那一栏出现。
    enum Scope: Hashable {
        case conversations, bookmarks, notes, compilations, mistakes, chat
    }

    struct Toast: Identifiable {
        let id = UUID()
        let scope: Scope
        let message: String
        let actionTitle: String
        let action: () -> Void
    }

    static let duration: Duration = .seconds(5)

    private(set) var current: Toast?
    /// 等着被删、暂时不显示的对象。
    private(set) var hiddenIDs: Set<PersistentIdentifier> = []
    private var pendingCommit: (() -> Void)?
    private var timer: Task<Void, Never>?

    func isHidden(_ model: some PersistentModel) -> Bool {
        hiddenIDs.contains(model.persistentModelID)
    }

    /// 删除一组对象，可以撤销。`commit` 真正删除，5 秒后或者下一次提示出现时执行。
    func delete(_ models: [any PersistentModel], scope: Scope, message: String = "已删除", commit: @escaping () -> Void) {
        guard !models.isEmpty else { return }
        flush()
        let ids = Set(models.map { $0.persistentModelID })
        hiddenIDs.formUnion(ids)
        pendingCommit = { [weak self] in
            self?.hiddenIDs.subtract(ids)
            commit()
        }
        show(Toast(scope: scope, message: message, actionTitle: "撤销") { [weak self] in
            self?.hiddenIDs.subtract(ids)
            self?.pendingCommit = nil
        })
    }

    /// 只显示一句话和一个按钮，不涉及删除。
    func show(_ message: String, scope: Scope, actionTitle: String, action: @escaping () -> Void) {
        flush()
        show(Toast(scope: scope, message: message, actionTitle: actionTitle, action: action))
    }

    /// 点了提示条上的按钮。
    func performAction() {
        guard let toast = current else { return }
        timer?.cancel()
        current = nil
        toast.action()
    }

    /// 立刻执行还在等的删除，收起提示条。
    func flush() {
        timer?.cancel()
        timer = nil
        current = nil
        let commit = pendingCommit
        pendingCommit = nil
        commit?()
    }

    private func show(_ toast: Toast) {
        current = toast
        timer = Task { [weak self] in
            try? await Task.sleep(for: Self.duration)
            guard !Task.isCancelled else { return }
            self?.flush()
        }
    }
}

extension View {
    /// 在这个页面底部显示属于 `scope` 的提示条。
    func toastBar(_ scope: ToastCenter.Scope) -> some View {
        modifier(ToastBarModifier(scope: scope))
    }
}

private struct ToastBarModifier: ViewModifier {
    let scope: ToastCenter.Scope
    @Environment(ToastCenter.self) private var toasts
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        content.overlay(alignment: .bottom) {
            if let toast = toasts.current, toast.scope == scope {
                ToastBar(toast: toast) { toasts.performAction() }
                    .padding(.horizontal, Theme.Spacing.l)
                    .padding(.bottom, Theme.Spacing.m)
                    .transition(reduceMotion ? .opacity : .move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(reduceMotion ? nil : .smooth(duration: 0.25), value: toasts.current?.id)
    }
}

private struct ToastBar: View {
    let toast: ToastCenter.Toast
    let onAction: () -> Void

    var body: some View {
        HStack(spacing: Theme.Spacing.m) {
            Text(toast.message)
                .font(.callout)
                .lineLimit(2)
            Spacer(minLength: 0)
            Button(toast.actionTitle, action: onAction)
                .font(.callout.bold())
        }
        .padding(.horizontal, Theme.Spacing.l)
        .padding(.vertical, Theme.Spacing.m)
        .frame(maxWidth: 480)
        .background(.regularMaterial, in: Capsule())
        .shadow(color: .black.opacity(0.12), radius: 8, y: 2)
        .accessibilityElement(children: .contain)
    }
}
