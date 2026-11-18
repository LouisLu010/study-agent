import StudyKit
import SwiftData
import SwiftUI

@main
struct StudyAgentApp: App {
    @State private var generation = GenerationCenter()
    @State private var navigation = AppNavigation()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(generation)
                .environment(navigation)
        }
        .modelContainer(for: StudyAgentSchema.models)
    }
}
