import Foundation
import StudyKit
import SwiftData
import Testing
@testable import StudyAgent

private enum ConceptCardStoreTestError: Error { case saveFailed }

@MainActor
@Suite struct ConceptCardStoreTests {
    @Test func splittingDeletesOriginalAndPreservesCardMetadataSourcesAndGroup() throws {
        let container = try makeContainer()
        let context = ModelContext(container)
        let note = originalNote()
        let noteID = note.id
        let conversationID = note.sourceConversationID
        let originalSources = note.sources
        context.insert(note)
        let image = StoredImage(data: Data("拆卡原图".utf8), contentType: "image/png")
        context.insert(image)
        let imageID = image.id
        note.content += "\n![](sa-asset:\(imageID.uuidString))"
        var proposed = try draft()
        proposed.cards[0].content += "\n![](sa-asset:\(imageID.uuidString))"

        let groupID = try ConceptCardStore.save(proposed, candidates: [], modelName: "拆卡模型", conversationID: nil, into: noteID, context: context)

        #expect(groupID == noteID)
        let reloaded = ModelContext(container)
        #expect(try reloaded.fetchCount(FetchDescriptor<ResearchNote>()) == 0)
        let cards = try reloaded.fetch(FetchDescriptor<ConceptCard>())
        #expect(cards.count == 2)
        #expect(cards.allSatisfy { $0.noteID == groupID && $0.sourceConversationID == conversationID })
        #expect(cards.allSatisfy { $0.subject == .math && $0.topic == "原始知识点" && $0.modelName == "拆卡模型" })
        for card in cards {
            let before = try #require(proposed.cards.first { $0.title == card.title })
            #expect(card.content == before.content && card.example == before.example)
            #expect(Array(card.sources.prefix(before.sources.count)) == before.sources)
            #expect(originalSources.allSatisfy { source in card.sources.contains { $0.url == source.url } })
            #expect(ConceptCardStore.originalNote(for: card, in: []) == nil)
        }
        let links = try reloaded.fetch(FetchDescriptor<ConceptLink>())
        #expect(links.count == 1)
        #expect(Set(cards.map(\.id)).isSuperset(of: links.flatMap { [$0.fromID, $0.toID].compactMap { $0 } }))
        #expect(try reloaded.fetch(FetchDescriptor<StoredImage>()).first?.id == imageID)
        #expect(try reloaded.fetch(FetchDescriptor<StoredImage>()).first?.data == Data("拆卡原图".utf8))
        let navigation = AppNavigation()
        navigation.recentNoteID = groupID
        #expect(cards.filter { $0.noteID == navigation.recentNoteID }.count == 2)
    }

    @Test func savingAnotherOpenPreviewReusesTheGroupAfterOriginalDeletion() throws {
        let container = try makeContainer()
        let context = ModelContext(container)
        let note = originalNote()
        context.insert(note)
        let preview = NoteDraftRequest.note(note, model: nil)
        let groupID = try ConceptCardStore.save(try draft(), candidates: [], modelName: "模型", conversationID: nil, into: preview.existingNoteID, context: context)
        let initialCards = Set(try context.fetch(FetchDescriptor<ConceptCard>()).map(\.id))
        let initialLinks = Set(try context.fetch(FetchDescriptor<ConceptLink>()).map(\.id))

        let other = ModelContext(container)
        let repeated = try ConceptCardStore.save(try draft(), candidates: [], modelName: "另一模型", conversationID: UUID(), into: preview.existingNoteID, context: other)

        #expect(repeated == groupID)
        #expect(preview.existingSubject == .math && preview.existingTopic == "原始知识点")
        #expect(preview.items.first?.content.contains("原文公式") == true)
        #expect(try other.fetchCount(FetchDescriptor<ResearchNote>()) == 0)
        #expect(Set(try other.fetch(FetchDescriptor<ConceptCard>()).map(\.id)) == initialCards)
        #expect(Set(try other.fetch(FetchDescriptor<ConceptLink>()).map(\.id)) == initialLinks)
    }

    @Test func deletingAllCardsDoesNotRecreateTheRemovedOriginal() throws {
        let container = try makeContainer()
        let context = ModelContext(container)
        let note = originalNote()
        let noteID = note.id
        context.insert(note)
        try ConceptCardStore.save(try draft(), candidates: [], modelName: "模型", conversationID: nil, into: noteID, context: context)
        for card in try context.fetch(FetchDescriptor<ConceptCard>()) { ConceptCardStore.delete(card, context: context) }

        let reloaded = ModelContext(container)
        #expect(try reloaded.fetchCount(FetchDescriptor<ResearchNote>()) == 0)
        #expect(try reloaded.fetchCount(FetchDescriptor<ConceptCard>()) == 0)
        #expect(try reloaded.fetchCount(FetchDescriptor<ConceptLink>()) == 0)
        #expect(throws: ConceptCardStore.OriginalCleanupError.self) {
            try ConceptCardStore.save(try draft(), candidates: [], modelName: "模型", conversationID: nil, into: noteID, context: reloaded)
        }
    }

    @Test func organizingNewCardsDoesNotCreateAnEmptyResearchNoteContainer() throws {
        let container = try makeContainer()
        let context = ModelContext(container)
        let conversationID = UUID()
        let groupID = try ConceptCardStore.save(try draft(), candidates: [], modelName: "模型", conversationID: conversationID, context: context)
        let reloaded = ModelContext(container)
        let cards = try reloaded.fetch(FetchDescriptor<ConceptCard>())
        #expect(try reloaded.fetchCount(FetchDescriptor<ResearchNote>()) == 0)
        #expect(cards.count == 2)
        #expect(cards.allSatisfy { $0.noteID == groupID && $0.sourceConversationID == conversationID })
    }

    @Test func failedSaveRestoresOriginalAndKeepsUnrelatedEdits() throws {
        let container = try makeContainer()
        let context = ModelContext(container)
        let note = originalNote()
        let noteID = note.id
        let content = note.content
        context.insert(note)
        context.insert(ResearchNote(title: "另一份资料", content: "尚未保存的编辑"))
        var saves = 0

        #expect(throws: ConceptCardStoreTestError.self) {
            try ConceptCardStore.save(try draft(), candidates: [], modelName: "模型", conversationID: nil, into: noteID, context: context, persist: { context in
                saves += 1
                if saves == 2 { throw ConceptCardStoreTestError.saveFailed }
                try context.save()
            })
        }

        let reloaded = ModelContext(container)
        let notes = try reloaded.fetch(FetchDescriptor<ResearchNote>())
        #expect(notes.first { $0.id == noteID }?.content == content)
        #expect(notes.first { $0.title == "另一份资料" }?.content == "尚未保存的编辑")
        #expect(try context.fetchCount(FetchDescriptor<ResearchNote>()) == 2)
        #expect(try reloaded.fetchCount(FetchDescriptor<ConceptCard>()) == 0)
        #expect(try reloaded.fetchCount(FetchDescriptor<ConceptLink>()) == 0)
    }

    @Test func cancelledSplitDoesNotModifyTheOriginal() async throws {
        let container = try makeContainer()
        let context = ModelContext(container)
        let note = originalNote()
        let noteID = note.id
        context.insert(note)
        try context.save()
        let proposed = try draft()
        let task = Task { @MainActor in
            withUnsafeCurrentTask { $0?.cancel() }
            return try ConceptCardStore.save(proposed, candidates: [], modelName: "模型", conversationID: nil, into: noteID, context: context)
        }
        await #expect(throws: CancellationError.self) { try await task.value }
        let reloaded = ModelContext(container)
        #expect(try reloaded.fetch(FetchDescriptor<ResearchNote>()).first?.id == noteID)
        #expect(try reloaded.fetchCount(FetchDescriptor<ConceptCard>()) == 0)
    }

    @Test func openingAPreviewDoesNotDeleteOriginalContent() throws {
        let container = try makeContainer()
        let context = ModelContext(container)
        let note = originalNote()
        context.insert(note)
        try context.save()
        let preview = NoteDraftRequest.note(note, model: nil)
        #expect(preview.items.first?.content.contains(note.content) == true)
        #expect(try ModelContext(container).fetchCount(FetchDescriptor<ResearchNote>()) == 1)
        #expect(try context.fetchCount(FetchDescriptor<ConceptCard>()) == 0)
    }

    @Test func anEmptyDraftNeverDeletesTheOriginal() throws {
        let container = try makeContainer()
        let context = ModelContext(container)
        let note = originalNote()
        let noteID = note.id
        context.insert(note)
        try context.save()
        var empty = try draft()
        empty.cards = []
        #expect(throws: ConceptCardStore.OriginalCleanupError.self) {
            try ConceptCardStore.save(empty, candidates: [], modelName: "模型", conversationID: nil, into: noteID, context: context)
        }
        #expect(try ModelContext(container).fetch(FetchDescriptor<ResearchNote>()).first?.id == noteID)
        #expect(try context.fetchCount(FetchDescriptor<ConceptCard>()) == 0)
    }

    @Test func migrationPreservesSourcesImagesAndLinksAndKeepsUnsplitNotes() throws {
        let container = try makeContainer()
        let context = ModelContext(container)
        let note = originalNote()
        let noteID = note.id
        let conversationID = note.sourceConversationID
        let originalSources = note.sources
        note.isCardBased = true
        context.insert(note)
        context.insert(ResearchNote(title: "未拆资料", content: "继续保留"))
        let orphan = ResearchNote(title: "没有卡的旧资料", content: "继续保留")
        orphan.isCardBased = true
        context.insert(orphan)
        let image = StoredImage(data: Data("原图".utf8), contentType: "image/png")
        context.insert(image)
        let imageID = image.id
        let first = ConceptCard(title: "已有卡", content: "原角标 [1] ![](sa-asset:\(imageID.uuidString))")
        first.noteID = noteID
        first.sources = [WebSource(url: "https://example.com/card-first", title: "已有首个来源")]
        first.example = "例子内容"
        first.pinnedPosition = MapPoint(x: 12, y: 34)
        let second = ConceptCard(title: "缺来源的卡", content: "第二卡 [1]")
        second.noteID = noteID
        context.insert(first)
        context.insert(second)
        let link = ConceptLink(from: first.id, to: second.id, kind: .prerequisite, reason: "先学定义")
        context.insert(link)
        let firstID = first.id
        let secondID = second.id
        let linkID = link.id
        let content = first.content

        #expect(try ConceptCardStore.removeCardBasedOriginals(context: context) == 1)
        #expect(try ConceptCardStore.removeCardBasedOriginals(context: context) == 0)

        let reloaded = ModelContext(container)
        #expect(Set(try reloaded.fetch(FetchDescriptor<ResearchNote>()).map(\.title)) == Set(["未拆资料", "没有卡的旧资料"]))
        let cards = try reloaded.fetch(FetchDescriptor<ConceptCard>())
        #expect(Set(cards.map(\.id)) == Set([firstID, secondID]))
        let savedFirst = try #require(cards.first { $0.id == firstID })
        let savedSecond = try #require(cards.first { $0.id == secondID })
        #expect(savedFirst.content == content && savedFirst.example == "例子内容")
        #expect(savedFirst.pinnedPosition == MapPoint(x: 12, y: 34))
        #expect(savedFirst.sources.map(\.url) == ["https://example.com/card-first", originalSources[0].url])
        #expect(savedSecond.sources == originalSources)
        #expect(cards.allSatisfy { $0.noteID == noteID && $0.sourceConversationID == conversationID })
        #expect(try reloaded.fetch(FetchDescriptor<ConceptLink>()).map(\.id) == [linkID])
        #expect(try reloaded.fetch(FetchDescriptor<StoredImage>()).first?.id == imageID)
        #expect(try reloaded.fetch(FetchDescriptor<StoredImage>()).first?.data == Data("原图".utf8))
    }

    @Test func migrationFailureRestoresOriginalAndCardSources() throws {
        let container = try makeContainer()
        let context = ModelContext(container)
        let note = originalNote()
        let noteID = note.id
        note.isCardBased = true
        context.insert(note)
        let card = ConceptCard(title: "卡", content: "内容")
        card.noteID = noteID
        context.insert(card)
        var saves = 0
        #expect(throws: ConceptCardStoreTestError.self) {
            try ConceptCardStore.removeCardBasedOriginals(context: context, persist: { context in
                saves += 1
                if saves == 2 { throw ConceptCardStoreTestError.saveFailed }
                try context.save()
            })
        }
        let reloaded = ModelContext(container)
        #expect(try reloaded.fetch(FetchDescriptor<ResearchNote>()).first?.id == noteID)
        #expect(try context.fetchCount(FetchDescriptor<ResearchNote>()) == 1)
        #expect(try reloaded.fetch(FetchDescriptor<ConceptCard>()).first?.sources.isEmpty == true)
        #expect(try reloaded.fetch(FetchDescriptor<ConceptCard>()).first?.sourceConversationID == nil)
    }

    @Test func missingCardImageKeepsTheOriginalAvailable() throws {
        let container = try makeContainer()
        let context = ModelContext(container)
        let note = originalNote()
        let noteID = note.id
        note.isCardBased = true
        context.insert(note)
        let card = ConceptCard(title: "卡", content: "![](sa-asset:\(UUID().uuidString))")
        card.noteID = noteID
        context.insert(card)
        #expect(throws: ConceptCardStore.OriginalCleanupError.self) { try ConceptCardStore.removeCardBasedOriginals(context: context) }
        let reloaded = ModelContext(container)
        #expect(try reloaded.fetch(FetchDescriptor<ResearchNote>()).first?.id == noteID)
        #expect(try reloaded.fetchCount(FetchDescriptor<ConceptCard>()) == 1)
    }

    @Test func undoingPendingDeletionPreservesPersistedCardsAndLinks() throws {
        let container = try makeContainer()
        let context = ModelContext(container)
        try ConceptCardStore.save(try draft(), candidates: [], modelName: "模型", conversationID: nil, context: context)
        let card = try #require(context.fetch(FetchDescriptor<ConceptCard>()).first)
        let toasts = ToastCenter()
        defer { toasts.flush() }
        var commits = 0
        toasts.delete([card], scope: .notes) { commits += 1; ConceptCardStore.delete(card, context: context) }
        #expect(toasts.isHidden(card))
        #expect(commits == 0)
        toasts.performAction()
        toasts.flush()
        #expect(!toasts.isHidden(card))
        #expect(commits == 0)
        let reloaded = ModelContext(container)
        #expect(try reloaded.fetchCount(FetchDescriptor<ResearchNote>()) == 0)
        #expect(try reloaded.fetchCount(FetchDescriptor<ConceptCard>()) == 2)
        #expect(try reloaded.fetchCount(FetchDescriptor<ConceptLink>()) == 1)
    }

    @Test func flushingPendingDeletionCommitsExactlyOnce() throws {
        let container = try makeContainer()
        let context = ModelContext(container)
        try ConceptCardStore.save(try draft(), candidates: [], modelName: "模型", conversationID: nil, context: context)
        let card = try #require(context.fetch(FetchDescriptor<ConceptCard>()).first)
        let toasts = ToastCenter()
        var commits = 0
        toasts.delete([card], scope: .notes) { commits += 1; ConceptCardStore.delete(card, context: context) }
        toasts.flush()
        toasts.flush()
        toasts.performAction()
        #expect(commits == 1)
        #expect(toasts.hiddenIDs.isEmpty && toasts.current == nil)
        let reloaded = ModelContext(container)
        #expect(try reloaded.fetchCount(FetchDescriptor<ResearchNote>()) == 0)
        #expect(try reloaded.fetchCount(FetchDescriptor<ConceptCard>()) == 1)
        #expect(try reloaded.fetchCount(FetchDescriptor<ConceptLink>()) == 0)
    }

    private func makeContainer() throws -> ModelContainer {
        try ModelContainer(for: Schema(StudyAgentSchema.models), configurations: ModelConfiguration(isStoredInMemoryOnly: true))
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
            sources: [WebSource(url: "https://example.com/cards", title: "卡片出处")], candidateCount: 0, fallbackTitle: "导数"
        )
    }
}
