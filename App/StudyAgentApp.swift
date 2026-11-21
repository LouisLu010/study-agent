import StudyKit
import SwiftData
import SwiftUI

@main
struct StudyAgentApp: App {
    @State private var generation = GenerationCenter()
    @State private var navigation = AppNavigation()
    @State private var compilations = CompilationCenter()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(generation)
                .environment(navigation)
                .environment(compilations)
        }
        .modelContainer(AppStore.container)
    }
}
