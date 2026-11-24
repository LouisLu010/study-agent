import StudyKit
import SwiftData
import SwiftUI

/// 按顺序复习今天到期的错题。开始时把到期的题定下来，复习过程中档位变化不会改变这一轮的题目。
struct ReviewSessionView: View {
    @Environment(\.modelContext) private var context
    @Environment(GenerationCenter.self) private var generation
    @Environment(AppNavigation.self) private var navigation

    @State private var queue: [Mistake] = []
    @State private var position = 0
    @State private var correctCount = 0
    @State private var didStart = false
    /// 当前这道题的结果，nil 表示还没答。
    @State private var answered: Bool?
    @State private var showSolution = false
    /// 每道题用一个新的 id，保证测验组件从空白状态开始。
    @State private var cardID = UUID()
    @State private var errorMessage: String?

    var body: some View {
        Group {
            if !didStart {
                ProgressView()
            } else if queue.isEmpty {
                OrbEmptyState(title: "今天没有要复习的题")
            } else if position >= queue.count {
                finished
            } else {
                card(queue[position])
            }
        }
        .sensoryFeedback(trigger: answered) { _, result in
            result.map { $0 ? SensoryFeedback.success : SensoryFeedback.error }
        }
        .navigationTitle(queue.isEmpty || position >= queue.count ? "复习" : "复习 \(position + 1) / \(queue.count)")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            guard !didStart else { return }
            let all = (try? context.fetch(FetchDescriptor<Mistake>(sortBy: [SortDescriptor(\.dueAt)]))) ?? []
            queue = all.filter { ReviewSchedule.isDue($0) }
            didStart = true
        }
        .alert("提示", isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })) {
            Button("好", role: .cancel) {}
        } message: {
            Text(errorMessage ?? "")
        }
    }

    // MARK: - 一道题

    private func card(_ mistake: Mistake) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                HStack {
                    Text([mistake.subject?.rawValue, mistake.topic].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · "))
                    Spacer()
                    Text("第 \(mistake.box + 1) 档")
                }
                .font(.caption)
                .foregroundStyle(.secondary)

                switch mistake.kind {
                case .quiz:
                    RenderedContentView(
                        id: cardID,
                        content: mistake.quizMarkdown,
                        onQuizResult: { payload in
                            guard answered == nil else { return }
                            record(mistake, correct: (payload["correct"] as? NSNumber)?.boolValue ?? false)
                        }
                    )
                case .manual:
                    ManualQuestionView(mistake: mistake)
                    if showSolution {
                        Divider()
                        Text("解答").font(.headline)
                        RenderedContentView(id: cardID, content: mistake.solution, componentStateJSON: mistake.solutionStateJSON)
                        if answered == nil {
                            HStack(spacing: 12) {
                                Button("还不会") { record(mistake, correct: false) }
                                    .buttonStyle(.bordered)
                                Button("会了") { record(mistake, correct: true) }
                                    .buttonStyle(.borderedProminent)
                            }
                            .frame(maxWidth: .infinity)
                        }
                    } else {
                        Button("看解答") { showSolution = true }
                            .buttonStyle(.borderedProminent)
                            .frame(maxWidth: .infinity)
                    }
                }

                if let answered {
                    resultBanner(mistake, correct: answered)
                }
            }
            .padding()
            .frame(maxWidth: 820)
            .frame(maxWidth: .infinity)
        }
    }

    private func resultBanner(_ mistake: Mistake, correct: Bool) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(
                correct
                    ? (mistake.isMastered ? "已掌握，不再出现在复习里" : "答对了，下次在 \(mistake.dueAt.formatted(.dateTime.month().day())) 复习")
                    : "回到第一档，明天再复习",
                systemImage: correct ? "checkmark.circle.fill" : "arrow.counterclockwise.circle.fill"
            )
            .foregroundStyle(correct ? Theme.success : .orange)
            HStack {
                Button("再来几道类似的", systemImage: "sparkles") { practiceSimilar(mistake) }
                    .buttonStyle(.bordered)
                Spacer()
                Button(position + 1 < queue.count ? "下一题" : "完成") { next() }
                    .buttonStyle(.borderedProminent)
            }
        }
        .padding(Theme.Spacing.l)
        .cardBackground()
    }

    private var finished: some View {
        OrbEmptyState(title: "复习完成", message: "这一轮复习了 \(queue.count) 道题，答对 \(correctCount) 道。")
    }

    // MARK: - 操作

    private func record(_ mistake: Mistake, correct: Bool) {
        ReviewSchedule.record(mistake, correct: correct)
        context.insert(StudyEvent(kind: .review, correct: correct, subject: mistake.subjectRaw, topic: mistake.topic))
        try? context.save()
        if correct { correctCount += 1 }
        answered = correct
        ReviewReminder.reschedule(in: context)
    }

    private func next() {
        position += 1
        answered = nil
        showSolution = false
        cardID = UUID()
    }

    private func practiceSimilar(_ mistake: Mistake) {
        do {
            try StudyCenter.startConversation(
                title: "练习：" + (mistake.topic.isEmpty ? "类似题" : mistake.topic),
                prompt: MistakePrompts.similar(to: mistake),
                context: context,
                generation: generation,
                navigation: navigation
            )
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
