import StudyKit
import SwiftData
import SwiftUI

struct MistakeDetailView: View {
    @Bindable var mistake: Mistake

    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @Environment(GenerationCenter.self) private var generation
    @Environment(AppNavigation.self) private var navigation
    @Environment(ToastCenter.self) private var toasts
    @State private var showSolution = false
    @State private var errorMessage: String?

    var body: some View {
        Form {
            Section("题目") {
                switch mistake.kind {
                case .quiz:
                    // 显示当时答错的样子：错误选项、正确答案和解析。
                    RenderedContentView(
                        id: mistake.id,
                        content: mistake.quizMarkdown,
                        componentStateJSON: wrongAnswerState,
                        onAsk: ask
                    )
                case .manual:
                    ManualQuestionView(mistake: mistake)
                }
            }

            if mistake.kind == .manual {
                Section("解答") {
                    if showSolution {
                        RenderedContentView(
                            id: mistake.id,
                            content: mistake.solution,
                            componentStateJSON: mistake.solutionStateJSON,
                            onComponentState: { key, state in
                                mistake.solutionStateJSON = ComponentStateStore.updating(
                                    mistake.solutionStateJSON, key: key, state: state
                                )
                                try? context.save()
                            },
                            onAsk: ask
                        )
                    } else {
                        Button("显示解答") { showSolution = true }
                    }
                }
            }

            Section("分类") {
                Picker("科目", selection: Binding(
                    get: { mistake.subject ?? .other },
                    set: { mistake.subject = $0 }
                )) {
                    ForEach(Subject.allCases) { Text($0.rawValue).tag($0) }
                }
                TextField("知识点", text: $mistake.topic)
                TextField("备注", text: $mistake.note, axis: .vertical)
            }

            Section("复习") {
                LabeledContent("状态", value: MistakeFormatting.status(mistake))
                LabeledContent("加入时间", value: mistake.createdAt.formatted(date: .abbreviated, time: .shortened))
                if mistake.reviewCount > 0 {
                    LabeledContent("复习次数", value: "\(mistake.reviewCount)")
                }
                Button("再来几道类似的", systemImage: "sparkles", action: practiceSimilar)
                if mistake.sourceConversationID != nil {
                    Button("查看原会话", systemImage: "bubble.left.and.text.bubble.right") {
                        if !navigation.open(conversationID: mistake.sourceConversationID, in: context) {
                            errorMessage = "原会话已经删除了。"
                        }
                    }
                }
            }

            Section {
                // 第九版：不再弹确认，回到错题本后可以撤销。
                Button("从错题本删除", role: .destructive) {
                    toasts.delete([mistake], scope: .mistakes) { [context, mistake] in
                        context.delete(mistake)
                        try? context.save()
                    }
                    dismiss()
                }
            }
        }
        .navigationTitle(mistake.topic.isEmpty ? "错题" : mistake.topic)
        .navigationBarTitleDisplayMode(.inline)
        .onDisappear { try? context.save() }
        .alert("提示", isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })) {
            Button("好", role: .cancel) {}
        } message: {
            Text(errorMessage ?? "")
        }
    }

    /// 测验组件的状态：第 0 题显示当时的错误作答。
    private var wrongAnswerState: String {
        mistake.wrongAnswerJSON.isEmpty ? "" : "{\"c0\":{\"answers\":{\"0\":\(mistake.wrongAnswerJSON)}}}"
    }

    private func practiceSimilar() {
        run {
            try StudyCenter.startConversation(
                title: "练习：" + (mistake.topic.isEmpty ? "类似题" : mistake.topic),
                prompt: MistakePrompts.similar(to: mistake),
                context: context,
                generation: generation,
                navigation: navigation
            )
        }
    }

    /// 错题里的"问问 AI"：新建会话来问，不打扰原会话。
    private func ask(_ text: String) {
        run {
            try StudyCenter.startConversation(
                title: "提问：" + (mistake.topic.isEmpty ? "错题" : mistake.topic),
                prompt: text,
                context: context,
                generation: generation,
                navigation: navigation
            )
        }
    }

    private func run(_ action: () throws -> Void) {
        do { try action() } catch { errorMessage = error.localizedDescription }
    }
}

/// 手动加入的错题：题目文字和图片。
struct ManualQuestionView: View {
    let mistake: Mistake

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            let images = mistake.imageData
            if !images.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        ForEach(Array(images.enumerated()), id: \.offset) { _, data in
                            ThumbnailView(data: data, size: images.count == 1 ? 200 : 110)
                        }
                    }
                }
            }
            if mistake.questionText.contains("sa-asset:") || mistake.questionText.contains("$") {
                // 从汇编加入的原题是 Markdown，里面有公式和原图。
                RenderedContentView(id: mistake.id, content: mistake.questionText)
            } else if !mistake.questionText.isEmpty {
                Text(mistake.questionText)
                    .textSelection(.enabled)
            }
            if !mistake.note.isEmpty {
                Label(mistake.note, systemImage: "note.text")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

enum MistakePrompts {
    /// "再来几道类似的"发给模型的消息。
    static func similar(to mistake: Mistake) -> String {
        let question: String
        switch mistake.kind {
        case .quiz: question = mistake.previewText
        case .manual:
            question = mistake.questionText.isEmpty
                ? "（原题是一张图片，参考下面的解答）\n" + mistake.solution
                : CompilationCenter.textForModel(mistake.questionText)
        }
        var lines = ["我之前做错了下面这道题，请出 3 道考查同一知识点的类似练习题，用测验组件出，难度相近或稍难一点。"]
        if let subject = mistake.subject { lines.append("科目：\(subject.rawValue)") }
        if !mistake.topic.isEmpty { lines.append("知识点：\(mistake.topic)") }
        lines.append("原题：\n" + question)
        return lines.joined(separator: "\n")
    }
}
