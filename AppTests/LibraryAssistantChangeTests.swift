import Foundation
import StudyKit
import SwiftData
import Testing
@testable import StudyAgent

@MainActor
@Suite struct LibraryAssistantChangeTests {
    @Test func emptyChangeDoesNotSaveOrTouchOtherEdits() throws {
        let context = try makeContext()
        let snapshot = try LibraryAssistantSnapshot(context: context)
        let change = LibraryAssistantChange(before: snapshot, after: snapshot, summary: "没有修改")
        let another = LibraryAssistantChange(before: snapshot, after: snapshot, summary: "另一条记录")
        context.insert(makeCard("稍后新建"))

        try change.undo(in: context) { _ in Issue.record("空操作不应保存上下文") }

        #expect(change.isEmpty)
        #expect(change.summary == "没有修改")
        #expect(change.id != another.id)
        #expect(change.changedCardIDs.isEmpty && change.changedNoteIDs.isEmpty && change.changedLinkIDs.isEmpty)
        #expect(context.hasChanges)
        #expect(try context.fetchCount(FetchDescriptor<ConceptCard>()) == 1)
    }

    @Test func snapshotTracksEveryCardFieldAndUndoRestoresIt() throws {
        let context = try makeContext()
        let card = makeCard("原卡")
        context.insert(card)
        try context.save()
        let before = try LibraryAssistantSnapshot(context: context)
        let edits: [() -> Void] = [
            { card.createdAt = Date(timeIntervalSince1970: 10) },
            { card.updatedAt = Date(timeIntervalSince1970: 20) },
            { card.title = "新标题" }, { card.content = "新内容" }, { card.example = "新例子" },
            { card.subjectRaw = "未来科目" }, { card.topic = "新知识点" },
            { card.sourcesJSON = "[ ]" }, { card.noteID = nil },
            { card.sourceConversationID = nil }, { card.modelName = "新模型" },
            { card.mapX = nil }, { card.mapY = 0 },
            { card.readingEvidenceData = Data([1, 2, 3]) },
        ]
        for edit in edits {
            edit()
            try context.save()
            let after = try LibraryAssistantSnapshot(context: context)
            let change = LibraryAssistantChange(before: before, after: after, summary: "编辑卡片")
            #expect(before != after)
            #expect(change.changedCardIDs == [card.id])
            #expect(change.changedNoteIDs.isEmpty && change.changedLinkIDs.isEmpty)
            try change.undo(in: context)
            #expect(try LibraryAssistantSnapshot(context: context) == before)
        }
        #expect(try LibraryAssistantSnapshot(context: ModelContext(context.container)) == before)
    }

    @Test func snapshotTracksEveryNoteFieldAndUndoRestoresIt() throws {
        let context = try makeContext()
        let note = makeNote("原资料")
        context.insert(note)
        try context.save()
        let before = try LibraryAssistantSnapshot(context: context)
        let edits: [() -> Void] = [
            { note.createdAt = Date(timeIntervalSince1970: 10) },
            { note.updatedAt = Date(timeIntervalSince1970: 20) },
            { note.title = "新标题" }, { note.content = "新内容" },
            { note.subjectRaw = "未来科目" }, { note.topic = "新知识点" },
            { note.componentStateJSON = "{}" }, { note.sourcesJSON = "[ ]" },
            { note.modelName = "新模型" }, { note.sourceConversationID = nil },
            { note.isCardBased = true },
        ]
        for edit in edits {
            edit()
            try context.save()
            let change = LibraryAssistantChange(before: before, after: try LibraryAssistantSnapshot(context: context), summary: "编辑资料")
            #expect(change.changedNoteIDs == [note.id])
            #expect(change.changedCardIDs.isEmpty && change.changedLinkIDs.isEmpty)
            try change.undo(in: context)
            #expect(try LibraryAssistantSnapshot(context: context) == before)
        }
        #expect(try LibraryAssistantSnapshot(context: ModelContext(context.container)) == before)
    }

    @Test func snapshotTracksEveryLinkFieldAndUndoRestoresIt() throws {
        let context = try makeContext()
        let a = makeCard("A"), b = makeCard("B")
        let link = makeLink(a, b)
        for card in [a, b] { context.insert(card) }
        context.insert(link)
        try context.save()
        let before = try LibraryAssistantSnapshot(context: context)
        let edits: [() -> Void] = [
            { link.createdAt = Date(timeIntervalSince1970: 10) },
            { link.fromID = nil }, { link.toID = nil }, { link.kindRaw = "未来关系" },
            { link.reason = "新理由" }, { link.isManual = true }, { link.dismissed = true },
        ]
        for edit in edits {
            edit()
            try context.save()
            let change = LibraryAssistantChange(before: before, after: try LibraryAssistantSnapshot(context: context), summary: "编辑关联")
            #expect(change.changedLinkIDs == [link.id])
            #expect(change.changedCardIDs.isEmpty && change.changedNoteIDs.isEmpty)
            try change.undo(in: context)
            #expect(try LibraryAssistantSnapshot(context: context) == before)
        }
    }

    @Test func undoMergeRestoresDeletedCardAndAllLinkDirections() throws {
        let context = try makeContext()
        let a = makeCard("保留卡"), b = makeCard("合并卡"), c = makeCard("其他卡")
        let internalLink = makeLink(a, b)
        let outgoing = makeLink(b, c)
        let incoming = makeLink(c, b)
        incoming.kind = .contrast
        incoming.dismissed = true
        incoming.isManual = true
        for card in [a, b, c] { context.insert(card) }
        for link in [internalLink, outgoing, incoming] { context.insert(link) }
        try context.save()
        let originalID = b.id
        let before = try LibraryAssistantSnapshot(context: context)

        a.content += "\n合并后的内容"
        a.updatedAt = .now
        outgoing.fromID = a.id
        incoming.toID = a.id
        context.delete(internalLink)
        context.delete(b)
        let added = makeLink(a, c)
        added.kind = .application
        context.insert(added)
        try context.save()
        let change = LibraryAssistantChange(before: before, after: try LibraryAssistantSnapshot(context: context), summary: "合并知识卡")

        try change.undo(in: context)

        let reloaded = ModelContext(context.container)
        #expect(try LibraryAssistantSnapshot(context: reloaded) == before)
        let restored = try #require(reloaded.fetch(FetchDescriptor<ConceptCard>()).first { $0.id == originalID })
        #expect(restored.title == "合并卡")
        #expect(restored.mapX == 24 && restored.mapY == -12)
        #expect(restored.createdAt == Date(timeIntervalSince1970: 100))
        #expect(restored.sourcesJSON == "[ { \"url\": \"https://example.com/source\", \"title\": \"出处\" } ]")
    }

    @Test func undoSplitRestoresOriginalNoteAndRemovesOnlyCreatedCards() throws {
        let context = try makeContext()
        let note = makeNote("完整原资料")
        let existing = makeCard("已有卡")
        context.insert(note)
        context.insert(existing)
        try context.save()
        let before = try LibraryAssistantSnapshot(context: context)
        let groupID = note.id
        let a = makeCard("拆卡 A"), b = makeCard("拆卡 B")
        for card in [a, b] {
            card.noteID = groupID
            context.insert(card)
        }
        context.insert(makeLink(a, b))
        context.insert(makeLink(b, existing))
        context.delete(note)
        try context.save()
        let change = LibraryAssistantChange(before: before, after: try LibraryAssistantSnapshot(context: context), summary: "拆分原资料")

        try change.undo(in: context)

        let reloaded = ModelContext(context.container)
        #expect(try LibraryAssistantSnapshot(context: reloaded) == before)
        let restored = try #require(reloaded.fetch(FetchDescriptor<ResearchNote>()).first)
        #expect(restored.id == groupID)
        #expect(restored.componentStateJSON == #"{"graph":{"zoom":2}}"#)
        #expect(!restored.isCardBased)
        #expect(try reloaded.fetchCount(FetchDescriptor<ConceptCard>()) == 1)
    }

    @Test func laterUnsavedCardEditRejectsWholeUndoWithoutRollback() throws {
        let context = try makeContext()
        let card = makeCard("原卡")
        context.insert(card)
        try context.save()
        let before = try LibraryAssistantSnapshot(context: context)
        card.content = "AI 修改"
        let added = makeNote("AI 新资料")
        context.insert(added)
        try context.save()
        let change = LibraryAssistantChange(before: before, after: try LibraryAssistantSnapshot(context: context), summary: "修改资料")
        card.example = "用户后来添加的例子"
        let latest = try LibraryAssistantSnapshot(context: context)

        #expect(throws: LibraryAssistantChange.UndoError.changedSinceOperation) { try change.undo(in: context) }

        #expect(try LibraryAssistantSnapshot(context: context) == latest)
        #expect(context.hasChanges)
        #expect(try context.fetchCount(FetchDescriptor<ResearchNote>()) == 1)
    }

    @Test func laterDeletionOfChangedRecordRejectsWholeUndo() throws {
        let context = try makeContext()
        let card = makeCard("原卡")
        context.insert(card)
        try context.save()
        let before = try LibraryAssistantSnapshot(context: context)
        card.content = "AI 修改"
        try context.save()
        let change = LibraryAssistantChange(before: before, after: try LibraryAssistantSnapshot(context: context), summary: "修改卡片")
        context.delete(card)
        try context.save()
        let latest = try LibraryAssistantSnapshot(context: context)

        #expect(throws: LibraryAssistantChange.UndoError.changedSinceOperation) { try change.undo(in: context) }
        #expect(try LibraryAssistantSnapshot(context: context) == latest)
    }

    @Test func editSavedByAnotherContextRejectsUndoOfCachedRecord() throws {
        let context = try makeContext()
        let card = makeCard("原卡")
        context.insert(card)
        try context.save()
        let before = try LibraryAssistantSnapshot(context: context)
        card.content = "AI 修改"
        try context.save()
        let change = LibraryAssistantChange(before: before, after: try LibraryAssistantSnapshot(context: context), summary: "修改卡片")
        let anotherContext = ModelContext(context.container)
        let anotherCard = try #require(anotherContext.fetch(FetchDescriptor<ConceptCard>()).first)
        anotherCard.content = "另一个页面保存的新内容"
        try anotherContext.save()
        let latest = try LibraryAssistantSnapshot(context: anotherContext)

        #expect(throws: LibraryAssistantChange.UndoError.changedSinceOperation) { try change.undo(in: context) }
        #expect(try LibraryAssistantSnapshot(context: ModelContext(context.container)) == latest)
    }

    @Test func snapshotsIncludePendingInsertsUpdatesAndDeletes() throws {
        let context = try makeContext()
        let original = makeNote("原资料")
        let a = makeCard("A"), b = makeCard("B")
        let deletedLink = makeLink(a, b)
        for card in [a, b] { context.insert(card) }
        context.insert(original)
        context.insert(deletedLink)
        try context.save()
        let before = try LibraryAssistantSnapshot(context: context)
        let deletedNoteID = original.id, deletedLinkID = deletedLink.id
        a.content = "待保存的修改"
        let added = makeCard("待保存的新卡")
        added.noteID = original.id
        context.insert(added)
        let newLink = makeLink(a, added)
        context.insert(newLink)
        context.delete(original)
        context.delete(deletedLink)
        // 与工具执行流程一致：保存前取得 after，保存成功后才能发出撤销记录。
        let after = try LibraryAssistantSnapshot(context: context)
        try context.save()
        let change = LibraryAssistantChange(before: before, after: after, summary: "修改资料")

        #expect(change.changedCardIDs == [a.id, added.id])
        #expect(change.changedNoteIDs == [deletedNoteID])
        #expect(change.changedLinkIDs == [deletedLinkID, newLink.id])
        try change.undo(in: context)
        #expect(try LibraryAssistantSnapshot(context: ModelContext(context.container)) == before)
    }

    @Test func laterLinkToNewCardPreventsDeletingThatCard() throws {
        let context = try makeContext()
        let existing = makeCard("已有卡")
        context.insert(existing)
        try context.save()
        let before = try LibraryAssistantSnapshot(context: context)
        let added = makeCard("AI 新卡")
        context.insert(added)
        try context.save()
        let change = LibraryAssistantChange(before: before, after: try LibraryAssistantSnapshot(context: context), summary: "创建知识卡")
        context.insert(makeLink(existing, added))
        try context.save()
        let latest = try LibraryAssistantSnapshot(context: context)

        #expect(throws: LibraryAssistantChange.UndoError.changedSinceOperation) { try change.undo(in: context) }
        #expect(try LibraryAssistantSnapshot(context: context) == latest)
    }

    @Test(arguments: [false, true])
    func laterChangeOrDeletionOfExistingMergeLinkRejectsUndo(deleteLink: Bool) throws {
        let context = try makeContext()
        let a = makeCard("保留卡"), b = makeCard("合并卡"), c = makeCard("相关卡")
        let link = makeLink(a, c)
        for card in [a, b, c] { context.insert(card) }
        context.insert(link)
        try context.save()
        let before = try LibraryAssistantSnapshot(context: context)
        a.content += b.content
        context.delete(b)
        try context.save()
        let change = LibraryAssistantChange(before: before, after: try LibraryAssistantSnapshot(context: context), summary: "合并卡片")
        // 该关联没有被合并操作修改，仍需保护事后对它的修改和删除。
        if deleteLink { context.delete(link) } else { link.reason = "用户后改的理由" }
        try context.save()
        let latest = try LibraryAssistantSnapshot(context: context)

        #expect(change.changedLinkIDs.isEmpty)
        #expect(throws: LibraryAssistantChange.UndoError.changedSinceOperation) { try change.undo(in: context) }
        #expect(try LibraryAssistantSnapshot(context: context) == latest)
    }

    @Test func laterCardInSplitGroupRejectsUndo() throws {
        let context = try makeContext()
        let note = makeNote("原资料")
        context.insert(note)
        try context.save()
        let before = try LibraryAssistantSnapshot(context: context)
        let groupID = note.id
        let first = makeCard("拆出的卡")
        first.noteID = groupID
        context.insert(first)
        context.delete(note)
        try context.save()
        let change = LibraryAssistantChange(before: before, after: try LibraryAssistantSnapshot(context: context), summary: "拆卡")
        let later = makeCard("用户后来加入的卡")
        later.noteID = groupID
        context.insert(later)
        try context.save()
        let latest = try LibraryAssistantSnapshot(context: context)

        #expect(throws: LibraryAssistantChange.UndoError.changedSinceOperation) { try change.undo(in: context) }
        #expect(try LibraryAssistantSnapshot(context: context) == latest)
    }

    @Test func deletedEndpointPreventsRestoringLink() throws {
        let context = try makeContext()
        let a = makeCard("A"), b = makeCard("B")
        let link = makeLink(a, b)
        for card in [a, b] { context.insert(card) }
        context.insert(link)
        try context.save()
        let before = try LibraryAssistantSnapshot(context: context)
        context.delete(link)
        try context.save()
        let change = LibraryAssistantChange(before: before, after: try LibraryAssistantSnapshot(context: context), summary: "删除关联")
        context.delete(b)
        try context.save()

        #expect(throws: LibraryAssistantChange.UndoError.changedSinceOperation) { try change.undo(in: context) }
        #expect(try context.fetchCount(FetchDescriptor<ConceptLink>()) == 0)
    }

    @Test func unrelatedAdditionsUpdatesAndDeletionsArePreserved() throws {
        let context = try makeContext()
        let edited = makeCard("本次卡片"), other = makeCard("其他卡片"), neighbor = makeCard("其他邻居")
        let note = makeNote("其他资料"), deletedNote = makeNote("稍后删除")
        let link = makeLink(other, neighbor)
        for card in [edited, other, neighbor] { context.insert(card) }
        for item in [note, deletedNote] { context.insert(item) }
        context.insert(link)
        try context.save()
        let originalContent = edited.content
        let before = try LibraryAssistantSnapshot(context: context)
        edited.content = "AI 修改"
        try context.save()
        let change = LibraryAssistantChange(before: before, after: try LibraryAssistantSnapshot(context: context), summary: "编辑卡片")

        other.content = "用户更新的其他卡片"
        note.content = "用户更新的其他资料"
        link.reason = "用户更新的其他关联"
        let newCard = makeCard("后加卡片"), newNote = makeNote("后加资料")
        context.insert(newCard)
        context.insert(newNote)
        let newLink = makeLink(other, newCard)
        context.insert(newLink)
        context.delete(deletedNote)
        // 留下未保存的改动，撤销必须先保存它们作为回滚基线。
        try change.undo(in: context)

        let reloaded = ModelContext(context.container)
        let cards = try reloaded.fetch(FetchDescriptor<ConceptCard>())
        let notes = try reloaded.fetch(FetchDescriptor<ResearchNote>())
        let links = try reloaded.fetch(FetchDescriptor<ConceptLink>())
        #expect(cards.first { $0.id == edited.id }?.content == originalContent)
        #expect(cards.first { $0.id == other.id }?.content == "用户更新的其他卡片")
        #expect(cards.contains { $0.id == newCard.id })
        #expect(notes.first { $0.id == note.id }?.content == "用户更新的其他资料")
        #expect(notes.contains { $0.id == newNote.id })
        #expect(!notes.contains { $0.id == deletedNote.id })
        #expect(links.first { $0.id == link.id }?.reason == "用户更新的其他关联")
        #expect(links.contains { $0.id == newLink.id })
    }

    @Test func failedSaveRollsBackAllUndoChangesToSavedBaseline() throws {
        let context = try makeContext()
        let original = makeNote("被拆原资料"), edited = makeCard("编辑卡")
        context.insert(original)
        context.insert(edited)
        try context.save()
        let before = try LibraryAssistantSnapshot(context: context)
        let added = makeCard("拆出的卡")
        added.noteID = original.id
        context.insert(added)
        let link = makeLink(edited, added)
        context.insert(link)
        edited.title = "AI 更新的标题"
        context.delete(original)
        try context.save()
        let change = LibraryAssistantChange(before: before, after: try LibraryAssistantSnapshot(context: context), summary: "修改资料")
        context.insert(makeNote("用户未保存的其他资料"))
        let latest = try LibraryAssistantSnapshot(context: context)
        var saves = 0

        #expect(throws: SaveFailure.expected) {
            try change.undo(in: context) { context in
                saves += 1
                if saves == 2 { throw SaveFailure.expected }
                try context.save()
            }
        }

        #expect(saves == 2)
        #expect(!context.hasChanges)
        #expect(try LibraryAssistantSnapshot(context: context) == latest)
        #expect(try LibraryAssistantSnapshot(context: ModelContext(context.container)) == latest)
    }

    @Test func baselineSaveFailureDoesNotRollBackPendingUserEdits() throws {
        let context = try makeContext()
        let card = makeCard("原卡")
        context.insert(card)
        try context.save()
        let before = try LibraryAssistantSnapshot(context: context)
        card.content = "AI 修改"
        try context.save()
        let change = LibraryAssistantChange(before: before, after: try LibraryAssistantSnapshot(context: context), summary: "编辑卡片")
        context.insert(makeNote("用户尚未保存的资料"))
        let latest = try LibraryAssistantSnapshot(context: context)

        #expect(throws: SaveFailure.expected) {
            try change.undo(in: context) { _ in throw SaveFailure.expected }
        }

        #expect(context.hasChanges)
        #expect(try LibraryAssistantSnapshot(context: context) == latest)
    }

    @Test func reverseOrderUndoWorksAfterRecordWasDeletedAndRecreated() throws {
        let context = try makeContext()
        let card = makeCard("原卡")
        context.insert(card)
        try context.save()
        let initial = try LibraryAssistantSnapshot(context: context)
        card.content = "第一次 AI 编辑"
        try context.save()
        let edited = try LibraryAssistantSnapshot(context: context)
        let first = LibraryAssistantChange(before: initial, after: edited, summary: "编辑")
        context.delete(card)
        context.insert(makeCard("第二次替换卡"))
        try context.save()
        let second = LibraryAssistantChange(before: edited, after: try LibraryAssistantSnapshot(context: context), summary: "替换")

        try second.undo(in: context)
        try first.undo(in: context)

        #expect(try LibraryAssistantSnapshot(context: ModelContext(context.container)) == initial)
    }

    @Test func deletedLegacyLinkRestoresNilEndpointsAndRawKind() throws {
        let context = try makeContext()
        let link = ConceptLink(from: UUID(), to: UUID(), kind: .prerequisite)
        link.fromID = nil
        link.toID = nil
        link.kindRaw = "legacy-kind"
        link.isManual = true
        link.dismissed = true
        context.insert(link)
        try context.save()
        let before = try LibraryAssistantSnapshot(context: context)
        context.delete(link)
        try context.save()
        let change = LibraryAssistantChange(before: before, after: try LibraryAssistantSnapshot(context: context), summary: "删除旧关联")

        try change.undo(in: context)

        #expect(try LibraryAssistantSnapshot(context: ModelContext(context.container)) == before)
    }

    @Test func duplicateIDsThrowInsteadOfCrashingOrOverwriting() throws {
        let context = try makeContext()
        let a = makeCard("A"), b = makeCard("B")
        b.id = a.id
        context.insert(a)
        context.insert(b)

        #expect(throws: LibraryAssistantChange.UndoError.duplicateIdentity) {
            _ = try LibraryAssistantSnapshot(context: context)
        }
    }

    private enum SaveFailure: Error { case expected }

    private func makeContext() throws -> ModelContext {
        let container = try ModelContainer(
            for: ConceptCard.self, ResearchNote.self, ConceptLink.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
        let context = ModelContext(container)
        context.autosaveEnabled = false
        return context
    }

    private func makeCard(_ title: String) -> ConceptCard {
        let card = ConceptCard(title: title, content: "原文 $f(x)$ [1]。")
        card.createdAt = Date(timeIntervalSince1970: 100)
        card.updatedAt = Date(timeIntervalSince1970: 200)
        card.example = "例子与原图 ![](sa-asset:\(UUID().uuidString))"
        card.subject = .math
        card.topic = "导数"
        card.sourcesJSON = "[ { \"url\": \"https://example.com/source\", \"title\": \"出处\" } ]"
        card.noteID = UUID()
        card.sourceConversationID = UUID()
        card.modelName = "原模型"
        card.mapX = 24
        card.mapY = -12
        return card
    }

    private func makeNote(_ title: String) -> ResearchNote {
        let note = ResearchNote(title: title, content: "完整原文与出处 [1]。")
        note.createdAt = Date(timeIntervalSince1970: 100)
        note.updatedAt = Date(timeIntervalSince1970: 200)
        note.subject = .math
        note.topic = "导数"
        note.componentStateJSON = #"{"graph":{"zoom":2}}"#
        note.sourcesJSON = "[ { \"url\": \"https://example.com/original\", \"title\": \"原出处\" } ]"
        note.sourceConversationID = UUID()
        note.modelName = "原模型"
        return note
    }

    private func makeLink(_ from: ConceptCard, _ to: ConceptCard) -> ConceptLink {
        let link = ConceptLink(from: from.id, to: to.id, kind: .prerequisite, reason: "原关联理由")
        link.createdAt = Date(timeIntervalSince1970: 100)
        return link
    }
}
