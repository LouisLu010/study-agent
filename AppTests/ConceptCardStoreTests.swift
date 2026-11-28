import Foundation
import StudyKit
import SwiftData
import Testing
@testable import StudyAgent

@MainActor
@Suite struct ConceptCardStoreTests {
    @Test func splittingPersistsOriginalContentAndMetadata() throws {
        let container = try makeContainer()
        let context = ModelContext(container)
        let note = originalNote()
        let originalContent = note.content
        let originalSources = note.sources
        let originalComponents = note.componentStateJSON
        let conversationID = note.sourceConversationID
        context.insert(note)
        try context.save()

        let saved = ConceptCardStore.save(
            try draft(), candidates: [], modelName: "拆卡模型",
            conversationID: nil, into: note, context: context
        )

        #expect(saved.id == note.id)
        let reloaded = ModelContext(container)
        let notes = try reloaded.fetch(FetchDescriptor<ResearchNote>())
        let persisted = try #require(notes.first)
        let cards = try reloaded.fetch(FetchDescriptor<ConceptCard>())
        #expect(notes.count == 1)
        #expect(persisted.isCardBased)
        #expect(persisted.title == "原始资料")
        #expect(persisted.content == originalContent)
        #expect(persisted.sources == originalSources)
        #expect(persisted.componentStateJSON == originalComponents)
        #expect(persisted.sourceConversationID == conversationID)
        #expect(persisted.modelName == "原始模型")
        #expect(cards.count == 2)
        #expect(cards.allSatisfy { $0.noteID == persisted.id })
        #expect(cards.allSatisfy { $0.subject == .math && $0.topic == "原始知识点" })
        #expect(cards.allSatisfy { $0.sourceConversationID == conversationID })
        #expect(cards.allSatisfy { $0.modelName == "拆卡模型" })
        for card in cards {
            #expect(ConceptCardStore.originalNote(for: card, in: notes)?.id == persisted.id)
        }
        #expect(try reloaded.fetchCount(FetchDescriptor<ConceptLink>()) == 1)
    }

    @Test func savingAlreadySplitNoteDoesNotDuplicateCardsOrLinks() throws {
        let container = try makeContainer()
        let context = ModelContext(container)
        let note = originalNote()
        context.insert(note)
        let draft = try draft()
        ConceptCardStore.save(
            draft, candidates: [], modelName: "模型", conversationID: nil,
            into: note, context: context
        )
        let initialCardIDs = Set(try context.fetch(FetchDescriptor<ConceptCard>()).map(\.id))
        let initialLinkIDs = Set(try context.fetch(FetchDescriptor<ConceptLink>()).map(\.id))

        // 新的上下文模拟另一个仍然打开的拆卡预览。
        let anotherContext = ModelContext(container)
        let sameNote = try #require(anotherContext.fetch(FetchDescriptor<ResearchNote>()).first)
        ConceptCardStore.save(
            draft, candidates: [], modelName: "另一个模型", conversationID: UUID(),
            into: sameNote, context: anotherContext
        )
        try anotherContext.save()

        let reloaded = ModelContext(container)
        #expect(try reloaded.fetchCount(FetchDescriptor<ResearchNote>()) == 1)
        #expect(Set(try reloaded.fetch(FetchDescriptor<ConceptCard>()).map(\.id)) == initialCardIDs)
        #expect(Set(try reloaded.fetch(FetchDescriptor<ConceptLink>()).map(\.id)) == initialLinkIDs)
    }

    @Test func deletingLastCardRestoresOriginalNoteAndRemovesLinks() throws {
        let container = try makeContainer()
        let context = ModelContext(container)
        let note = originalNote()
        let originalContent = note.content
        let originalSources = note.sources
        let originalComponents = note.componentStateJSON
        context.insert(note)
        ConceptCardStore.save(
            try draft(), candidates: [], modelName: "模型", conversationID: nil,
            into: note, context: context
        )
        let cards = try context.fetch(FetchDescriptor<ConceptCard>())
        try #require(cards.count == 2)

        ConceptCardStore.delete(cards[0], context: context)

        let afterFirstDeletion = ModelContext(container)
        let remainingNote = try #require(afterFirstDeletion.fetch(FetchDescriptor<ResearchNote>()).first)
        #expect(remainingNote.isCardBased)
        #expect(remainingNote.content == originalContent)
        #expect(try afterFirstDeletion.fetchCount(FetchDescriptor<ConceptCard>()) == 1)
        #expect(try afterFirstDeletion.fetchCount(FetchDescriptor<ConceptLink>()) == 0)

        ConceptCardStore.delete(cards[1], context: context)

        let reloaded = ModelContext(container)
        let restored = try #require(reloaded.fetch(FetchDescriptor<ResearchNote>()).first)
        #expect(restored.id == note.id)
        #expect(!restored.isCardBased)
        #expect(restored.content == originalContent)
        #expect(restored.sources == originalSources)
        #expect(restored.componentStateJSON == originalComponents)
        #expect(try reloaded.fetchCount(FetchDescriptor<ConceptCard>()) == 0)
        #expect(try reloaded.fetchCount(FetchDescriptor<ConceptLink>()) == 0)
    }

    @Test func deletingLastCardRemovesNewEmptyContainer() throws {
        let container = try makeContainer()
        let context = ModelContext(container)
        let note = ConceptCardStore.save(
            try draft(), candidates: [], modelName: "模型",
            conversationID: nil, context: context
        )
        let cards = try context.fetch(FetchDescriptor<ConceptCard>())
        try #require(cards.count == 2)
        #expect(note.content.isEmpty)
        #expect(ConceptCardStore.originalNote(for: cards[0], in: [note]) == nil)

        for card in cards {
            ConceptCardStore.delete(card, context: context)
        }

        let reloaded = ModelContext(container)
        #expect(try reloaded.fetchCount(FetchDescriptor<ResearchNote>()) == 0)
        #expect(try reloaded.fetchCount(FetchDescriptor<ConceptCard>()) == 0)
        #expect(try reloaded.fetchCount(FetchDescriptor<ConceptLink>()) == 0)
    }

    @Test func originalCanBeSplitAgainAfterLastCardDeletion() throws {
        let container = try makeContainer()
        let context = ModelContext(container)
        let note = originalNote()
        context.insert(note)
        let draft = try draft()
        ConceptCardStore.save(
            draft, candidates: [], modelName: "模型", conversationID: nil,
            into: note, context: context
        )
        for card in try context.fetch(FetchDescriptor<ConceptCard>()) {
            ConceptCardStore.delete(card, context: context)
        }

        let reopened = ModelContext(container)
        let original = try #require(reopened.fetch(FetchDescriptor<ResearchNote>()).first)
        #expect(!original.isCardBased)
        ConceptCardStore.save(
            draft, candidates: [], modelName: "模型", conversationID: nil,
            into: original, context: reopened
        )

        let reloaded = ModelContext(container)
        let split = try #require(reloaded.fetch(FetchDescriptor<ResearchNote>()).first)
        #expect(split.id == note.id)
        #expect(split.isCardBased)
        #expect(split.content == note.content)
        #expect(try reloaded.fetchCount(FetchDescriptor<ResearchNote>()) == 1)
        #expect(try reloaded.fetchCount(FetchDescriptor<ConceptCard>()) == 2)
        #expect(try reloaded.fetchCount(FetchDescriptor<ConceptLink>()) == 1)
    }

    @Test func undoingPendingDeletionPreservesPersistedCard() throws {
        let container = try makeContainer()
        let context = ModelContext(container)
        let note = originalNote()
        context.insert(note)
        ConceptCardStore.save(
            try draft(), candidates: [], modelName: "模型", conversationID: nil,
            into: note, context: context
        )
        let card = try #require(context.fetch(FetchDescriptor<ConceptCard>()).first)
        let toasts = ToastCenter()
        defer { toasts.flush() }
        var commits = 0
        toasts.delete([card], scope: .notes) {
            commits += 1
            ConceptCardStore.delete(card, context: context)
        }

        #expect(toasts.isHidden(card))
        #expect(toasts.current?.actionTitle == "撤销")
        #expect(try ModelContext(container).fetchCount(FetchDescriptor<ConceptCard>()) == 2)
        #expect(commits == 0)

        toasts.performAction()
        toasts.flush()

        #expect(!toasts.isHidden(card))
        #expect(toasts.current == nil)
        #expect(commits == 0)
        let reloaded = ModelContext(container)
        let persisted = try #require(reloaded.fetch(FetchDescriptor<ResearchNote>()).first)
        #expect(persisted.isCardBased)
        #expect(persisted.content == note.content)
        #expect(try reloaded.fetchCount(FetchDescriptor<ConceptCard>()) == 2)
        #expect(try reloaded.fetchCount(FetchDescriptor<ConceptLink>()) == 1)
    }

    @Test func flushingPendingDeletionCommitsExactlyOnce() throws {
        let container = try makeContainer()
        let context = ModelContext(container)
        let note = originalNote()
        context.insert(note)
        ConceptCardStore.save(
            try draft(), candidates: [], modelName: "模型", conversationID: nil,
            into: note, context: context
        )
        let card = try #require(context.fetch(FetchDescriptor<ConceptCard>()).first)
        let toasts = ToastCenter()
        var commits = 0
        toasts.delete([card], scope: .notes) {
            commits += 1
            ConceptCardStore.delete(card, context: context)
        }

        toasts.flush()
        toasts.flush()
        toasts.performAction()

        #expect(commits == 1)
        #expect(toasts.hiddenIDs.isEmpty)
        #expect(toasts.current == nil)
        let reloaded = ModelContext(container)
        #expect(try reloaded.fetchCount(FetchDescriptor<ConceptCard>()) == 1)
        #expect(try reloaded.fetchCount(FetchDescriptor<ConceptLink>()) == 0)
        #expect(try reloaded.fetch(FetchDescriptor<ResearchNote>()).first?.isCardBased == true)
    }

    private func makeContainer() throws -> ModelContainer {
        try ModelContainer(
            for: Schema(StudyAgentSchema.models),
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
    }

    private func originalNote() -> ResearchNote {
        let note = ResearchNote(title: "原始资料", content: "# 导数\n\n原文公式 $f'(x)$ 与引用 [1]。")
        note.subject = .math
        note.topic = "原始知识点"
        note.sources = [WebSource(url: "https://example.com/original", title: "原始出处")]
        note.componentStateJSON = #"{"graph-1":{"zoom":2}}"#
        note.modelName = "原始模型"
        note.sourceConversationID = UUID()
        return note
    }

    private func draft() throws -> ConceptCardWriter.Draft {
        try ConceptCardWriter.parse(
            #"{"title":"导数和极值","subject":"数学","topic":"导数的应用","cards":[{"key":"c1","title":"导数定义","content":"定义内容 [1]","example":""},{"key":"c2","title":"求极值","content":"方法内容","example":""}],"links":[{"from":"c1","to":"c2","kind":"prerequisite","reason":"先求导"}]}"#,
            sources: [WebSource(url: "https://example.com/cards", title: "卡片出处")],
            candidateCount: 0,
            fallbackTitle: "导数"
        )
    }
}
