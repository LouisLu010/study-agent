import StudyKit
import SwiftData
import SwiftUI

@main
struct StudyAgentApp: App {
    /// 长按图标的快捷菜单要通过场景代理接收（见 QuickActions.swift）。
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var generation = GenerationCenter()
    @State private var navigation = AppNavigation()
    @State private var compilations = CompilationCenter()
    @State private var toasts = ToastCenter()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(generation)
                .environment(navigation)
                .environment(compilations)
                .environment(toasts)
        }
        .modelContainer(AppStore.container)
    }
}
