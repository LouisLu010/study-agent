import StudyKit
import SwiftData
import SwiftUI

enum StudyAssistantExamples {
    static let prompts = [
        "找出我以前学过的导数内容，告诉我可以从哪里接着学。",
        "分析我最近两周收录的数学错题，找出可能反复出现的问题，并引用原记录。",
        "用我已有的化学知识卡和汇编，组织一次有机化学专题学习。",
    ]
}

struct StudyAssistantHomeView: View {
    @Environment(\.modelContext) private var context
    @Environment(GenerationCenter.self) private var generation
    @Environment(AppNavigation.self) private var navigation
    @Environment(ToastCenter.self) private var toasts
    @Query private var models: [ChatModel]
    @Query(filter: #Predicate<Conversation> { $0.isStudyAssistant }, sort: \Conversation.updatedAt, order: .reverse)
    private var conversations: [Conversation]
    @State private var model: ChatModel?
    @State private var draft = ""
    @State private var images: [PendingImage] = []
    @State private var errorMessage: String?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Spacing.l) {
                Label("从你学过的内容开始", systemImage: "sparkles")
                    .font(.title2.bold())
                Text("查找会话、分析错题，或用知识卡和汇编组织一次专题学习。回答会附上可打开的原记录。")
                    .foregroundStyle(.secondary)
                if models.isEmpty {
                    Button("先添加模型") { navigation.showsOnboarding = true }
                        .buttonStyle(.borderedProminent)
                } else {
                    ComposerView(
                        text: $draft, images: $images, imagesAllowed: model?.supportsImages ?? false,
                        isGenerating: false, canSend: model != nil && (!draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !images.isEmpty),
                        onSend: send, onStop: {},
                        onImagesNotAllowed: { errorMessage = GenerationError.modelDoesNotSupportImages.localizedDescription },
                        webSearchEnabled: .constant(false), webSearchAllowed: false, onWebSearchNotAllowed: {},
                        model: $model, placement: .inline, showsWebSearch: false
                    )
                    Text("按需读取的本地文字会发送给所选模型。需要支持工具调用的模型。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                ForEach(StudyAssistantExamples.prompts, id: \.self) { prompt in
                    Button { draft = prompt } label: {
                        HStack {
                            Text(prompt).multilineTextAlignment(.leading)
                            Spacer()
                            Image(systemName: "arrow.up.left")
                        }
                        .padding()
                        .groupedCardBackground()
                    }
                    .buttonStyle(.plain)
                }
                let recent = conversations.filter { !toasts.isHidden($0) && !($0.messages ?? []).isEmpty }.prefix(5)
                if !recent.isEmpty {
                    Text("继续上次的学习").font(.headline)
                    ForEach(Array(recent)) { conversation in
                        Button { navigation.selection = .conversation(conversation) } label: {
                            HStack {
                                Text(conversation.title).lineLimit(2)
                                Spacer()
                                Image(systemName: "chevron.right")
                            }
                            .padding()
                            .groupedCardBackground()
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .padding()
            .frame(maxWidth: 720)
            .frame(maxWidth: .infinity)
        }
        .groupedPageBackground()
        .navigationTitle("学习助手")
        .accessibilityIdentifier("study-assistant-home")
        .task { if model == nil { model = ModelLookup.defaultModel(in: context) } }
        .onChange(of: models.count) { if model == nil || model?.modelContext == nil { model = ModelLookup.defaultModel(in: context) } }
        .alert("提示", isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })) {
            Button("好", role: .cancel) {}
        } message: { Text(errorMessage ?? "") }
    }

    private func send() {
        guard let model else { return }
        let conversation = Conversation()
        conversation.isStudyAssistant = true
        context.insert(conversation)
        conversation.model = model
        do {
            try context.save()
            try generation.send(draft.trimmingCharacters(in: .whitespacesAndNewlines), images: images.map(\.data), in: conversation, context: context)
            draft = ""
            images = []
            navigation.selection = .conversation(conversation)
        } catch {
            context.delete(conversation)
            try? context.save()
            errorMessage = ChatErrorDescription.describe(error)
        }
    }
}
