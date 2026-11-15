import StudyKit
import SwiftData
import SwiftUI

@main
struct StudyAgentApp: App {
    @State private var generation = GenerationCenter()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(generation)
        }
        .modelContainer(for: [Provider.self, ChatModel.self, Conversation.self, Message.self, Attachment.self])
    }
}
