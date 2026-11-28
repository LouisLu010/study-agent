import StudyKit
import SwiftData
import SwiftUI

/// 要整理成资料的内容，用来驱动 `.sheet(item:)`。
struct NoteDraftRequest: Identifiable {
    let id = UUID()
    let items: [ResearchNoteWriter.Item]
    let fallbackTitle: String
    let model: ChatModel?
    let conversationID: UUID?
    /// 只保存快照，另一个预览完成拆卡后不会访问已经删除的模型。
    var existingNoteID: UUID?
    var existingSubject: Subject?
    var existingTopic: String?

    /// 整个会话。
    static func conversation(_ conversation: Conversation) -> NoteDraftRequest {
        NoteDraftRequest(
            items: conversation.sortedMessages.map(item(for:)),
            fallbackTitle: conversation.title,
            model: conversation.model,
            conversationID: conversation.id
        )
    }

    /// 一条回答，连同它前面那条提问。
    static func reply(_ message: Message) -> NoteDraftRequest {
        let conversation = message.conversation
        let question = conversation?.sortedMessages.last { $0.role == .user && $0.index < message.index }
        return NoteDraftRequest(
            items: [question, message].compactMap { $0 }.map(item(for:)),
            fallbackTitle: conversation?.title ?? "资料",
            model: conversation?.model,
            conversationID: conversation?.id
        )
    }

    /// 一份以前的整篇资料，拆成知识卡。用默认模型。
    static func note(_ note: ResearchNote, model: ChatModel?) -> NoteDraftRequest {
        NoteDraftRequest(
            items: [ResearchNoteWriter.Item(role: .assistant, content: "# \(note.title)\n\n" + note.content, sources: note.sources)],
            fallbackTitle: note.title,
            model: model,
            conversationID: note.sourceConversationID,
            existingNoteID: note.id,
            existingSubject: note.subject,
            existingTopic: note.topic
        )
    }

    private static func item(for message: Message) -> ResearchNoteWriter.Item {
        var content = message.contentWithStudySources
        if message.role == .user, !message.imageData.isEmpty {
            content = "（附了 \(message.imageData.count) 张图片）\n" + content
        }
        return ResearchNoteWriter.Item(
            role: message.role,
            content: content,
            sources: message.webSearch?.displayedSources ?? []
        )
    }
}

/// 让模型把内容整理成知识卡和关联（第十版），预览后保存。
struct NoteDraftSheet: View {
    let request: NoteDraftRequest

    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @Environment(AppNavigation.self) private var navigation
    @State private var raw = ""
    @State private var draft: ConceptCardWriter.Draft?
    @State private var isGenerating = false
    @State private var isRepairing = false
    @State private var errorText: String?
    @State private var task: Task<Void, Never>?
    @State private var candidates: [ConceptCardWriter.Candidate] = []
    private let prepared: (text: String, sources: [WebSource])

    init(request: NoteDraftRequest) {
        self.request = request
        self.prepared = ResearchNoteWriter.prepare(request.items)
    }

    var body: some View {
        NavigationStack {
            List {
                if let errorText {
                    Label(errorText, systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.red)
                }
                if isGenerating {
                    HStack(spacing: Theme.Spacing.s) {
                        ActivityOrb(activity: .working)
                        Text(isRepairing ? "格式有误，正在重试…" : raw.isEmpty ? "正在整理…" : "正在整理…已写 \(raw.count) 字")
                            .foregroundStyle(.secondary)
                    }
                }
                if let draft {
                    Section {
                        VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
                            Text(draft.title).font(.headline)
                            Text([(request.existingSubject ?? draft.subject)?.rawValue ?? "", request.existingTopic ?? draft.topic]
                                .filter { !$0.isEmpty }.joined(separator: " · "))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    Section("\(draft.cards.count) 张知识卡") {
                        ForEach(Array(draft.cards.enumerated()), id: \.offset) { _, card in
                            VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
                                Text(card.title).fontWeight(.medium)
                                Text(PlainTextExporter.previewText(from: card.content))
                                    .font(.subheadline)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(3)
                            }
                            .padding(.vertical, 2)
                        }
                    }
                    if !draft.links.isEmpty {
                        Section("\(draft.links.count) 条关联") {
                            ForEach(Array(draft.links.enumerated()), id: \.offset) { _, link in
                                VStack(alignment: .leading, spacing: 2) {
                                    Text("\(title(link.from)) \(link.kind.isDirected ? "→" : "—") \(title(link.to))")
                                        .font(.subheadline)
                                    Text(link.kind.displayName + (link.reason.isEmpty ? "" : " · " + link.reason))
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                }
            }
            .navigationTitle(request.existingNoteID == nil ? "整理成资料" : "拆成知识卡")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") {
                        task?.cancel()
                        dismiss()
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存", action: save)
                        .disabled(isGenerating || draft == nil)
                }
                ToolbarItem(placement: .bottomBar) {
                    Button("重新整理", systemImage: "arrow.clockwise", action: start)
                        .disabled(isGenerating)
                }
            }
        }
        .task { start() }
        .onDisappear { task?.cancel() }
    }

    private func title(_ ref: ConceptCardWriter.Ref) -> String {
        switch ref {
        case let .new(index): return draft?.cards[safe: index]?.title ?? "?"
        case let .old(index): return (candidates[safe: index]?.title ?? "?") + "（已有）"
        }
    }

    private func start() {
        task?.cancel()
        raw = ""
        draft = nil
        errorText = nil
        isRepairing = false
        guard let model = request.model else {
            errorText = GenerationError.noModel.localizedDescription
            return
        }
        let service: any ChatService
        do {
            service = try ModelLookup.service(for: model)
        } catch {
            errorText = ChatErrorDescription.describe(error)
            return
        }
        let ownCards = Set(ConceptCardStore.allCards(in: context).filter { $0.noteID != nil && $0.noteID == request.existingNoteID }.map(\.id))
        candidates = ConceptCardWriter.selectCandidates(
            ConceptCardStore.candidates(ConceptCardStore.allCards(in: context)).filter { !ownCards.contains($0.id) },
            subject: request.existingSubject,
            topic: request.existingTopic ?? ""
        )
        let chatRequest = ConceptCardWriter.request(
            model: model.modelID, material: prepared.text, candidates: candidates, reasoningEffort: model.reasoningEffort
        )
        let sources = prepared.sources
        let count = candidates.count
        let fallback = request.fallbackTitle
        isGenerating = true
        task = Task {
            defer { isGenerating = false }
            do {
                for try await event in service.streamChat(chatRequest) {
                    if case let .text(delta) = event { raw += delta }
                }
                do {
                    draft = try ConceptCardWriter.parse(raw, sources: sources, candidateCount: count, fallbackTitle: fallback)
                } catch let error as ConceptCardWriter.ParseError {
                    // 解析失败：自动重试一次，只让模型修好这个 JSON。
                    isRepairing = true
                    var fixed = ""
                    for try await event in service.streamChat(ConceptCardWriter.repairRequest(model: model.modelID, raw: raw, error: error.message)) {
                        if case let .text(delta) = event { fixed += delta }
                    }
                    do {
                        draft = try ConceptCardWriter.parse(fixed, sources: sources, candidateCount: count, fallbackTitle: fallback)
                    } catch let error as ConceptCardWriter.ParseError {
                        errorText = "模型给出的格式有误（\(error.message)），可以点\"重新整理\"再试一次。"
                    }
                }
            } catch {
                if !Task.isCancelled { errorText = ChatErrorDescription.describe(error) }
            }
        }
    }

    private func save() {
        guard let draft else { return }
        do {
            let groupID = try ConceptCardStore.save(
                draft,
                candidates: candidates,
                modelName: request.model?.name ?? "",
                conversationID: request.conversationID,
                into: request.existingNoteID,
                context: context
            )
            // 整理完直接打开这次整理出的卡。
            navigation.recentNoteID = groupID
            navigation.selection = .notes
            dismiss()
        } catch {
            errorText = ChatErrorDescription.describe(error)
        }
    }
}

extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
