import Foundation
import StudyKit
import SwiftData
import Testing
@testable import StudyAgent

@MainActor
private final class LibraryToolboxFixture {
    let container: ModelContainer
    let context: ModelContext
    var changes: [LibraryAssistantChange] = []
    var changeCount: Int { changes.count }
    lazy var toolbox = LibraryAssistantToolbox(context: context, modelName: "资料测试模型") { [weak self] change in
        self?.changes.append(change)
    }

    init() throws {
        container = try ModelContainer(for: Schema(StudyAgentSchema.models), configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        context = ModelContext(container)
    }

    func card(_ title: String, content: String = "完整定义与条件。", subject: Subject = .math) -> ConceptCard {
        let card = ConceptCard(title: title, content: content)
        card.subject = subject
        card.topic = "导数"
        context.insert(card)
        return card
    }

    func note(_ title: String = "原资料", content: String = "定义、条件、例子与出处 [1]。") -> ResearchNote {
        let note = ResearchNote(title: title, content: content)
        note.subject = .math
        note.topic = "导数"
        note.sourceConversationID = UUID()
        note.sources = [WebSource(url: "https://example.org/original", title: "原出处")]
        context.insert(note)
        return note
    }

    func image() -> StoredImage {
        let image = StoredImage(data: Data("原图片字节".utf8), contentType: "image/png")
        context.insert(image)
        return image
    }
}

@MainActor
@Suite struct LibraryAssistantToolboxTests {
    private func call(_ name: String, _ input: JSONValue) -> ToolCall {
        ToolCall(id: UUID().uuidString, name: name, arguments: input.jsonString)
    }

    private func execute(_ toolbox: LibraryAssistantToolbox, _ name: String, _ input: JSONValue) async throws -> JSONValue {
        let result = try await toolbox.execute(call(name, input))
        let json = try #require(JSONValue.parse(result.content))
        #expect(json["error"] == nil)
        return json
    }

    private func rejected(_ toolbox: LibraryAssistantToolbox, _ name: String, _ input: JSONValue) async {
        await #expect(throws: LibraryAssistantTools.ArgumentError.self) {
            try await toolbox.execute(call(name, input))
        }
    }

    private func readCards(_ toolbox: LibraryAssistantToolbox, _ cards: [ConceptCard]) async throws -> [UUID: String] {
        let result = try await execute(toolbox, "read_cards", ["ids": .array(cards.map { .string($0.id.uuidString) })])
        let values = try #require(result["cards"]?.arrayValue)
        var revisions: [UUID: String] = [:]
        for value in values {
            let id = try #require(value["id"]?.stringValue.flatMap(UUID.init(uuidString:)))
            let revision = try #require(value["revision"]?.stringValue)
            #expect(!revision.isEmpty)
            revisions[id] = revision
        }
        #expect(Set(revisions.keys) == Set(cards.map(\.id)))
        return revisions
    }

    private func update(_ card: ConceptCard, revision: String, content: String? = nil, subject: Subject? = nil) -> JSONValue {
        [
            "id": .string(card.id.uuidString), "revision": .string(revision), "title": .string(card.title),
            "content": .string(content ?? card.content), "example": .string(card.example),
            "subject": .string((subject ?? card.subject)?.rawValue ?? ""), "topic": .string(card.topic),
        ]
    }

    private func merge(_ cards: [ConceptCard], revisions: [UUID: String], content: String = "合并后的完整定义与条件。") -> JSONValue {
        [
            "ids": .array(cards.map { .string($0.id.uuidString) }),
            "revisions": .array(cards.map { .string(revisions[$0.id] ?? "invalid") }),
            "title": "合并卡", "content": .string(content), "example": "", "subject": "数学", "topic": "导数",
        ]
    }

    private func organize(_ note: ResearchNote, revision: String, content: String = "整理后的完整知识 [1]。") -> JSONValue {
        [
            "id": .string(note.id.uuidString), "revision": .string(revision), "title": "整理导数资料",
            "subject": "数学", "topic": "导数", "cards": [["title": "定义", "content": .string(content), "example": "原例子。"]],
        ]
    }

    @Test func listingDoesNotAuthorizeWritingEvenWithAKnownRevision() async throws {
        let fixture = try LibraryToolboxFixture()
        let card = fixture.card("导数定义")
        try fixture.context.save()
        let anotherSession = LibraryAssistantToolbox(context: fixture.context, modelName: "另一会话")
        let revisions = try await readCards(anotherSession, [card])
        _ = try await execute(fixture.toolbox, "list_cards", ["query": "导数", "subject": "数学", "offset": 0, "limit": 10])

        await rejected(fixture.toolbox, "update_cards", ["updates": .array([update(card, revision: revisions[card.id]!, content: "不能写入")])])

        #expect(card.content == "完整定义与条件。")
        #expect(fixture.changeCount == 0)
        #expect(try ModelContext(fixture.container).fetch(FetchDescriptor<ConceptCard>()).first?.content == "完整定义与条件。")
    }

    @Test func updatePersistsActualContentAndPreservesSourcesImagesAndLinks() async throws {
        let fixture = try LibraryToolboxFixture()
        let image = fixture.image()
        let card = fixture.card("导数定义", content: "原定义 [1]。\n![](sa-asset:\(image.id))")
        card.example = "原例子 $x=1$。"
        card.sources = [WebSource(url: "https://example.org/definition", title: "定义来源")]
        card.noteID = UUID()
        card.sourceConversationID = UUID()
        card.pinnedPosition = MapPoint(x: 12, y: 34)
        let neighbor = fixture.card("导数应用")
        let link = ConceptLink(from: card.id, to: neighbor.id, kind: .application, reason: "应用定义", isManual: true)
        fixture.context.insert(link)
        let originalSources = card.sources
        let originalNoteID = card.noteID
        let originalConversationID = card.sourceConversationID
        let linkID = link.id
        let imageID = image.id
        try fixture.context.save()
        let revisions = try await readCards(fixture.toolbox, [card])
        let content = "保留条件 $x>0$ 的精简定义 [1]。\n![](sa-asset:\(imageID))"

        _ = try await execute(fixture.toolbox, "update_cards", ["updates": .array([update(card, revision: revisions[card.id]!, content: content)])])

        let reloaded = ModelContext(fixture.container)
        let saved = try #require(reloaded.fetch(FetchDescriptor<ConceptCard>()).first { $0.id == card.id })
        let expected = "保留条件 $x>0$ 的精简定义 [[1]](<https://example.org/definition>)。\n![](sa-asset:\(imageID))"
        #expect(saved.content == expected && saved.example == "原例子 $x=1$。")
        #expect(saved.sources == originalSources)
        #expect(saved.noteID == originalNoteID && saved.sourceConversationID == originalConversationID)
        #expect(saved.pinnedPosition == MapPoint(x: 12, y: 34))
        #expect(try reloaded.fetch(FetchDescriptor<ConceptLink>()).map(\.id) == [linkID])
        #expect(try reloaded.fetch(FetchDescriptor<StoredImage>()).first?.data == Data("原图片字节".utf8))
        #expect(fixture.changeCount == 1)
    }

    @Test func staleRevisionCannotOverwriteAUserEdit() async throws {
        let fixture = try LibraryToolboxFixture()
        let card = fixture.card("原卡")
        try fixture.context.save()
        let revisions = try await readCards(fixture.toolbox, [card])
        card.content = "用户刚刚编辑的内容。"
        try fixture.context.save()

        await rejected(fixture.toolbox, "update_cards", ["updates": .array([update(card, revision: revisions[card.id]!, content: "旧模型建议")])])

        #expect(card.content == "用户刚刚编辑的内容。")
        #expect(fixture.changeCount == 0)
    }

    @Test func updateCannotOverwriteChangesSavedByAnotherContext() async throws {
        let fixture = try LibraryToolboxFixture()
        let card = fixture.card("原卡")
        try fixture.context.save()
        let revisions = try await readCards(fixture.toolbox, [card])
        let other = ModelContext(fixture.container)
        other.autosaveEnabled = false
        let changed = try #require(other.fetch(FetchDescriptor<ConceptCard>()).first { $0.id == card.id })
        changed.content = "另一窗口保存的新内容。"
        try other.save()

        await rejected(fixture.toolbox, "update_cards", ["updates": .array([
            update(card, revision: revisions[card.id]!, content: "基于旧内容的修改"),
        ])])

        let saved = try #require(ModelContext(fixture.container).fetch(FetchDescriptor<ConceptCard>()).first)
        #expect(saved.content == "另一窗口保存的新内容。")
        #expect(fixture.changeCount == 0)
    }

    @Test func nanCoordinatesDoNotHideChangesFromRevisionValidation() async throws {
        let fixture = try LibraryToolboxFixture()
        let card = fixture.card("旧坐标卡")
        card.mapX = .nan
        card.mapY = 10
        try fixture.context.save()
        let revisions = try await readCards(fixture.toolbox, [card])
        // iOS 的持久化层可能把 NaN 规范化为 nil，两种情况下正文版本都必须有效。
        #expect(card.mapX == nil || card.mapX?.isNaN == true)
        card.content = "读取后由用户修改的正文。"
        try fixture.context.save()

        await rejected(fixture.toolbox, "update_cards", ["updates": .array([
            update(card, revision: revisions[card.id]!, content: "使用旧版本覆盖正文"),
        ])])

        #expect(card.content == "读取后由用户修改的正文。")
        #expect(try ModelContext(fixture.container).fetch(FetchDescriptor<ConceptCard>()).first?.content == "读取后由用户修改的正文。")
        #expect(fixture.changeCount == 0)
        let reread = try await readCards(fixture.toolbox, [card])
        #expect(reread[card.id] != revisions[card.id])
    }

    @Test func batchUpdateValidatesEveryCardBeforeChangingAny() async throws {
        let fixture = try LibraryToolboxFixture()
        let first = fixture.card("第一卡")
        let second = fixture.card("第二卡")
        try fixture.context.save()
        let revisions = try await readCards(fixture.toolbox, [first, second])

        await rejected(fixture.toolbox, "update_cards", ["updates": .array([
            update(first, revision: revisions[first.id]!, content: "第一卡的新内容"),
            update(second, revision: "wrong-revision", content: "第二卡的新内容"),
        ])])

        #expect(first.content == "完整定义与条件。" && second.content == "完整定义与条件。")
        #expect(fixture.changeCount == 0)
        #expect(try ModelContext(fixture.container).fetch(FetchDescriptor<ConceptCard>()).allSatisfy { $0.content == "完整定义与条件。" })
    }

    @Test func changingSourcesInvalidatesTheReadVersion() async throws {
        let fixture = try LibraryToolboxFixture()
        let card = fixture.card("原卡", content: "原知识 [1]。")
        card.sources = [WebSource(url: "https://example.org/old", title: "旧来源")]
        try fixture.context.save()
        let revisions = try await readCards(fixture.toolbox, [card])
        card.sources = [WebSource(url: "https://example.org/new", title: "新来源")]
        try fixture.context.save()

        await rejected(fixture.toolbox, "update_cards", ["updates": .array([update(card, revision: revisions[card.id]!, content: "旧知识 [1]。")])])

        #expect(card.content == "原知识 [1]。")
        #expect(card.sources.first?.url == "https://example.org/new")
        #expect(fixture.changeCount == 0)
    }

    @Test func droppingAnOriginalImageOrInventingAnAssetIsRejected() async throws {
        let fixture = try LibraryToolboxFixture()
        let image = fixture.image()
        let original = "原定义。\n![](sa-asset:\(image.id))"
        let card = fixture.card("图片卡", content: original)
        try fixture.context.save()
        let revisions = try await readCards(fixture.toolbox, [card])

        for content in ["丢掉图片的改写", original + "\n![](sa-asset:\(UUID()))"] {
            await rejected(fixture.toolbox, "update_cards", ["updates": .array([update(card, revision: revisions[card.id]!, content: content)])])
            #expect(card.content == original)
        }
        #expect(image.data == Data("原图片字节".utf8))
        #expect(fixture.changeCount == 0)
    }

    @Test func unknownCitationCannotIntroduceANewSource() async throws {
        let fixture = try LibraryToolboxFixture()
        let card = fixture.card("原卡", content: "原知识 [1]。")
        card.sources = [WebSource(url: "https://example.org/known", title: "原出处")]
        try fixture.context.save()
        let before = try LibraryAssistantSnapshot(context: fixture.context)
        let revisions = try await readCards(fixture.toolbox, [card])

        await rejected(fixture.toolbox, "update_cards", ["updates": .array([
            update(card, revision: revisions[card.id]!, content: "虚构引用 [[1]](<https://example.org/unknown>)。"),
        ])])

        #expect(try LibraryAssistantSnapshot(context: ModelContext(fixture.container)) == before)
        #expect(fixture.changeCount == 0)
    }

    @Test func citationLikeLiteralsInCodeAndMathRemainUntouched() async throws {
        let fixture = try LibraryToolboxFixture()
        let card = fixture.card("语法示例")
        card.sources = [WebSource(url: "https://example.org/known", title: "原出处")]
        try fixture.context.save()
        let revisions = try await readCards(fixture.toolbox, [card])
        let content = """
        `[[1]](<https://example.org/code>)` 与 $a[2]$。
        ```text
        [[2]](<https://example.org/fence>)
        ```
        """

        _ = try await execute(fixture.toolbox, "update_cards", ["updates": .array([
            update(card, revision: revisions[card.id]!, content: content),
        ])])

        #expect(try ModelContext(fixture.container).fetch(FetchDescriptor<ConceptCard>()).first?.content == content)
        #expect(fixture.changeCount == 1)
    }

    @Test func unknownCitationInTheSecondUpdateRollsBackTheEntireBatch() async throws {
        let fixture = try LibraryToolboxFixture()
        let first = fixture.card("第一卡")
        let second = fixture.card("第二卡")
        try fixture.context.save()
        let before = try LibraryAssistantSnapshot(context: fixture.context)
        let revisions = try await readCards(fixture.toolbox, [first, second])

        await rejected(fixture.toolbox, "update_cards", ["updates": .array([
            update(first, revision: revisions[first.id]!, content: "第一张有效的改写"),
            update(second, revision: revisions[second.id]!, content: "第二张虚构的引用 [[1]](<https://example.org/unknown>)"),
        ])])

        #expect(try LibraryAssistantSnapshot(context: fixture.context) == before)
        #expect(try LibraryAssistantSnapshot(context: ModelContext(fixture.container)) == before)
        #expect(fixture.changeCount == 0)
    }

    @Test func unknownCitationDuringOrganizationKeepsOriginalAndCreatesNoCards() async throws {
        let fixture = try LibraryToolboxFixture()
        let note = fixture.note()
        try fixture.context.save()
        let before = try LibraryAssistantSnapshot(context: fixture.context)
        let result = try await execute(fixture.toolbox, "read_note", ["id": .string(note.id.uuidString)])
        let revision = try #require(result["note"]?["revision"]?.stringValue)
        let request: JSONValue = [
            "id": .string(note.id.uuidString), "revision": .string(revision), "title": "拆分知识",
            "subject": "数学", "topic": "导数", "cards": [
                ["title": "第一卡", "content": "有效知识 [1]。", "example": ""],
                ["title": "第二卡", "content": "未知来源 [[1]](<https://example.org/unknown>)。", "example": ""],
            ],
        ]

        await rejected(fixture.toolbox, "organize_note", request)

        #expect(try LibraryAssistantSnapshot(context: fixture.context) == before)
        #expect(try LibraryAssistantSnapshot(context: ModelContext(fixture.container)) == before)
        #expect(fixture.changeCount == 0)
    }

    @Test func linkedCardsCannotSilentlyMoveToAnotherSubject() async throws {
        let fixture = try LibraryToolboxFixture()
        let card = fixture.card("定义")
        let neighbor = fixture.card("应用")
        let link = ConceptLink(from: card.id, to: neighbor.id, kind: .application)
        fixture.context.insert(link)
        try fixture.context.save()
        let revisions = try await readCards(fixture.toolbox, [card])

        await rejected(fixture.toolbox, "update_cards", ["updates": .array([update(card, revision: revisions[card.id]!, subject: .physics)])])

        #expect(card.subject == .math)
        #expect(try fixture.context.fetch(FetchDescriptor<ConceptLink>()).map(\.id) == [link.id])
        #expect(fixture.changeCount == 0)
    }

    @Test func mergeCombinesSourcesAndRetargetsDeduplicatedLinksWithoutDanglingIDs() async throws {
        let fixture = try LibraryToolboxFixture()
        let image = fixture.image()
        let first = fixture.card("定义一", content: "第一份定义 [1]。\n![](sa-asset:\(image.id))")
        let second = fixture.card("定义二", content: "第二份定义 [1]。")
        first.sources = [WebSource(url: "https://example.org/one", title: "来源一")]
        second.sources = [WebSource(url: "https://example.org/two", title: "来源二"), WebSource(url: "https://example.org/one", title: "重复来源")]
        let prerequisite = fixture.card("前置知识")
        let application = fixture.card("应用")
        for link in [
            ConceptLink(from: prerequisite.id, to: first.id, kind: .prerequisite, reason: "前置一"),
            ConceptLink(from: prerequisite.id, to: second.id, kind: .prerequisite, reason: "前置二", isManual: true),
            ConceptLink(from: second.id, to: application.id, kind: .application, reason: "应用关系"),
            ConceptLink(from: first.id, to: second.id, kind: .contrast, reason: "合并后不能自己连自己"),
        ] { fixture.context.insert(link) }
        try fixture.context.save()
        let result = try await execute(fixture.toolbox, "read_cards", ["ids": .array([first, second].map { .string($0.id.uuidString) })])
        let mergedSources = try #require(result["merge_sources"]?.arrayValue)
        #expect(Set(mergedSources.compactMap { $0["url"]?.stringValue }) == Set(["https://example.org/one", "https://example.org/two"]))
        let revisions = try await readCards(fixture.toolbox, [first, second])
        let content = "统一定义 [1][2]。\n![](sa-asset:\(image.id))"

        _ = try await execute(fixture.toolbox, "merge_cards", merge([first, second], revisions: revisions, content: content))

        let reloaded = ModelContext(fixture.container)
        let cards = try reloaded.fetch(FetchDescriptor<ConceptCard>())
        #expect(cards.count == 3)
        let saved = try #require(cards.first { $0.title == "合并卡" })
        #expect(saved.content == "统一定义 [[1]](<https://example.org/one>)[[2]](<https://example.org/two>)。\n![](sa-asset:\(image.id))")
        #expect(Set(saved.sources.map(\.url)) == Set(["https://example.org/one", "https://example.org/two"]))
        let links = try reloaded.fetch(FetchDescriptor<ConceptLink>())
        #expect(links.count == 2)
        #expect(links.contains { $0.fromID == prerequisite.id && $0.toID == saved.id && $0.kind == .prerequisite })
        let deduplicated = try #require(links.first { $0.fromID == prerequisite.id && $0.toID == saved.id })
        #expect(deduplicated.isManual)
        #expect(deduplicated.reason.contains("前置一") && deduplicated.reason.contains("前置二"))
        #expect(links.contains { $0.fromID == saved.id && $0.toID == application.id && $0.kind == .application })
        #expect(links.allSatisfy { $0.fromID != $0.toID })
        #expect(Set(cards.map(\.id)).isSuperset(of: links.flatMap { [$0.fromID, $0.toID].compactMap { $0 } }))
        #expect(try reloaded.fetch(FetchDescriptor<StoredImage>()).first?.data == Data("原图片字节".utf8))
        #expect(fixture.changeCount == 1)
    }

    @Test func mergeRejectsUnreadStaleAndCrossSubjectCardsWithoutDeletion() async throws {
        let fixture = try LibraryToolboxFixture()
        let first = fixture.card("数学卡")
        let second = fixture.card("物理卡", subject: .physics)
        try fixture.context.save()
        await rejected(fixture.toolbox, "merge_cards", merge([first, second], revisions: [:]))
        let revisions = try await readCards(fixture.toolbox, [first, second])
        await rejected(fixture.toolbox, "merge_cards", merge([first, second], revisions: revisions))
        second.subject = .math
        try fixture.context.save()
        await rejected(fixture.toolbox, "merge_cards", merge([first, second], revisions: revisions))

        #expect(try ModelContext(fixture.container).fetchCount(FetchDescriptor<ConceptCard>()) == 2)
        #expect(first.title == "数学卡" && second.title == "物理卡")
        #expect(fixture.changeCount == 0)
    }

    @Test func organizingRequiresReadingAndDeletesTheOriginalOnlyAfterSavingCards() async throws {
        let fixture = try LibraryToolboxFixture()
        let image = fixture.image()
        let note = fixture.note(content: "原始定义、条件和例子 [1]。\n![](sa-asset:\(image.id))")
        let noteID = note.id
        let conversationID = note.sourceConversationID
        let sources = note.sources
        try fixture.context.save()
        await rejected(fixture.toolbox, "organize_note", organize(note, revision: "unread"))
        #expect(try fixture.context.fetchCount(FetchDescriptor<ResearchNote>()) == 1)
        let result = try await execute(fixture.toolbox, "read_note", ["id": .string(noteID.uuidString)])
        let original = try #require(result["note"])
        let revision = try #require(original["revision"]?.stringValue)
        let content = "完整定义和条件 [1]。\n![](sa-asset:\(image.id))"

        _ = try await execute(fixture.toolbox, "organize_note", organize(note, revision: revision, content: content))

        let reloaded = ModelContext(fixture.container)
        #expect(try reloaded.fetchCount(FetchDescriptor<ResearchNote>()) == 0)
        let card = try #require(reloaded.fetch(FetchDescriptor<ConceptCard>()).first)
        #expect(card.content == "完整定义和条件 [[1]](<https://example.org/original>)。\n![](sa-asset:\(image.id))" && card.example == "原例子。")
        #expect(card.sources == sources && card.noteID == noteID)
        #expect(card.sourceConversationID == conversationID)
        #expect(card.subject == .math && card.topic == "导数")
        #expect(try reloaded.fetch(FetchDescriptor<StoredImage>()).first?.data == Data("原图片字节".utf8))
        #expect(fixture.changeCount == 1)
    }

    @Test func staleNoteRevisionDoesNotCreateCardsOrDeleteTheNewerOriginal() async throws {
        let fixture = try LibraryToolboxFixture()
        let note = fixture.note()
        try fixture.context.save()
        let result = try await execute(fixture.toolbox, "read_note", ["id": .string(note.id.uuidString)])
        let revision = try #require(result["note"]?["revision"]?.stringValue)
        note.content = "用户更新后的原资料。"
        try fixture.context.save()

        await rejected(fixture.toolbox, "organize_note", organize(note, revision: revision))

        let reloaded = ModelContext(fixture.container)
        #expect(try reloaded.fetchCount(FetchDescriptor<ConceptCard>()) == 0)
        #expect(try reloaded.fetch(FetchDescriptor<ResearchNote>()).first?.content == "用户更新后的原资料。")
        #expect(fixture.changeCount == 0)
    }

    @Test func organizationCannotDeleteANoteChangedByAnotherContext() async throws {
        let fixture = try LibraryToolboxFixture()
        let note = fixture.note()
        try fixture.context.save()
        let result = try await execute(fixture.toolbox, "read_note", ["id": .string(note.id.uuidString)])
        let revision = try #require(result["note"]?["revision"]?.stringValue)
        let other = ModelContext(fixture.container)
        other.autosaveEnabled = false
        let changed = try #require(other.fetch(FetchDescriptor<ResearchNote>()).first { $0.id == note.id })
        changed.content = "另一窗口保存的原文和必要条件。"
        try other.save()
        let before = try LibraryAssistantSnapshot(context: ModelContext(fixture.container))

        await rejected(fixture.toolbox, "organize_note", organize(note, revision: revision))

        #expect(try LibraryAssistantSnapshot(context: ModelContext(fixture.container)) == before)
        #expect(try ModelContext(fixture.container).fetchCount(FetchDescriptor<ConceptCard>()) == 0)
        #expect(fixture.changeCount == 0)
    }

    @Test func unknownIDsCannotCreateAnObjectByUpdatingIt() async throws {
        let fixture = try LibraryToolboxFixture()
        let card = ConceptCard(title: "不存在", content: "不允许创建")
        await rejected(fixture.toolbox, "read_cards", ["ids": .array([.string(card.id.uuidString)])])
        await rejected(fixture.toolbox, "update_cards", ["updates": .array([update(card, revision: "made-up")])])
        await rejected(fixture.toolbox, "read_note", ["id": .string(UUID().uuidString)])
        #expect(try fixture.context.fetchCount(FetchDescriptor<ConceptCard>()) == 0)
        #expect(try fixture.context.fetchCount(FetchDescriptor<ResearchNote>()) == 0)
        #expect(fixture.changeCount == 0)
    }

    @Test func mergeRequiresReadingItsExactGroupAndOrder() async throws {
        let fixture = try LibraryToolboxFixture()
        let first = fixture.card("第一卡")
        let second = fixture.card("第二卡")
        try fixture.context.save()
        var revisions = try await readCards(fixture.toolbox, [first])
        revisions.merge(try await readCards(fixture.toolbox, [second])) { _, new in new }
        await rejected(fixture.toolbox, "merge_cards", merge([first, second], revisions: revisions))
        revisions = try await readCards(fixture.toolbox, [first, second])
        await rejected(fixture.toolbox, "merge_cards", merge([second, first], revisions: revisions))
        #expect(try fixture.context.fetchCount(FetchDescriptor<ConceptCard>()) == 2)
        #expect(fixture.changeCount == 0)
    }

    @Test func changedSourcesRequireReadingTheWholeMergeGroupAgain() async throws {
        let fixture = try LibraryToolboxFixture()
        let first = fixture.card("第一卡")
        let second = fixture.card("第二卡")
        first.sources = [WebSource(url: "https://example.org/one", title: "一")]
        second.sources = [WebSource(url: "https://example.org/two", title: "二")]
        try fixture.context.save()
        var revisions = try await readCards(fixture.toolbox, [first, second])
        first.sources.insert(WebSource(url: "https://example.org/new", title: "用户新加出处"), at: 0)
        try fixture.context.save()
        revisions.merge(try await readCards(fixture.toolbox, [first])) { _, new in new }

        await rejected(fixture.toolbox, "merge_cards", merge([first, second], revisions: revisions, content: "旧编号的结论 [2]。"))

        #expect(try fixture.context.fetchCount(FetchDescriptor<ConceptCard>()) == 2)
        #expect(fixture.changeCount == 0)
    }

    @Test func mergeRelationshipConflictRollsBackAllChanges() async throws {
        let fixture = try LibraryToolboxFixture()
        let first = fixture.card("第一卡")
        let second = fixture.card("第二卡")
        let neighbor = fixture.card("邻居")
        fixture.context.insert(ConceptLink(from: neighbor.id, to: first.id, kind: .prerequisite, reason: "保留的关联"))
        let dismissed = ConceptLink(from: neighbor.id, to: second.id, kind: .prerequisite, reason: "用户删除的关联")
        dismissed.dismissed = true
        fixture.context.insert(dismissed)
        try fixture.context.save()
        let before = try LibraryAssistantSnapshot(context: fixture.context)
        let revisions = try await readCards(fixture.toolbox, [first, second])

        await rejected(fixture.toolbox, "merge_cards", merge([first, second], revisions: revisions))

        #expect(try LibraryAssistantSnapshot(context: fixture.context) == before)
        #expect(try LibraryAssistantSnapshot(context: ModelContext(fixture.container)) == before)
        #expect(fixture.changeCount == 0)
    }

    @Test func mergeCannotReplaceLinkChangesSavedByAnotherContext() async throws {
        let fixture = try LibraryToolboxFixture()
        let first = fixture.card("第一卡")
        let second = fixture.card("第二卡")
        let neighbor = fixture.card("关联卡")
        let link = ConceptLink(from: second.id, to: neighbor.id, kind: .application, reason: "旧关联说明")
        fixture.context.insert(link)
        try fixture.context.save()
        let revisions = try await readCards(fixture.toolbox, [first, second])
        let other = ModelContext(fixture.container)
        other.autosaveEnabled = false
        let changed = try #require(other.fetch(FetchDescriptor<ConceptLink>()).first { $0.id == link.id })
        changed.reason = "另一窗口更新的关联说明"
        changed.isManual = true
        try other.save()
        let before = try LibraryAssistantSnapshot(context: ModelContext(fixture.container))

        await rejected(fixture.toolbox, "merge_cards", merge([first, second], revisions: revisions))

        #expect(try LibraryAssistantSnapshot(context: ModelContext(fixture.container)) == before)
        #expect(fixture.changeCount == 0)
    }

    @Test func mergeBeyondTheRelationshipLimitKeepsAllOriginalRelations() async throws {
        let fixture = try LibraryToolboxFixture()
        let first = fixture.card("第一卡")
        let second = fixture.card("第二卡")
        for index in 0..<(LinkRules.maxPerCard + 1) {
            let neighbor = fixture.card("邻居 \(index)")
            fixture.context.insert(ConceptLink(from: index.isMultiple(of: 2) ? first.id : second.id, to: neighbor.id, kind: .application))
        }
        try fixture.context.save()
        let before = try LibraryAssistantSnapshot(context: fixture.context)
        let revisions = try await readCards(fixture.toolbox, [first, second])

        await rejected(fixture.toolbox, "merge_cards", merge([first, second], revisions: revisions))

        #expect(try LibraryAssistantSnapshot(context: fixture.context) == before)
        #expect(try fixture.context.fetchCount(FetchDescriptor<ConceptLink>()) == LinkRules.maxPerCard + 1)
        #expect(fixture.changeCount == 0)
    }

    @Test func oversizedReadsCannotAuthorizeTruncatedContentChanges() async throws {
        let fixture = try LibraryToolboxFixture()
        let large = String(repeating: "a", count: 120_001)
        let card = fixture.card("超长卡", content: large)
        let note = fixture.note("超长原文", content: large)
        try fixture.context.save()

        await rejected(fixture.toolbox, "read_cards", ["ids": .array([.string(card.id.uuidString)])])
        await rejected(fixture.toolbox, "update_cards", ["updates": .array([update(card, revision: "unread", content: "截断摘要")])])
        await rejected(fixture.toolbox, "read_note", ["id": .string(note.id.uuidString)])
        await rejected(fixture.toolbox, "organize_note", organize(note, revision: "unread"))

        #expect(card.content == large && note.content == large)
        #expect(fixture.changeCount == 0)
    }

    @Test func successfulWriteInvalidatesItsPreviousReadRevision() async throws {
        let fixture = try LibraryToolboxFixture()
        let card = fixture.card("原卡")
        try fixture.context.save()
        let revisions = try await readCards(fixture.toolbox, [card])
        _ = try await execute(fixture.toolbox, "update_cards", ["updates": .array([update(card, revision: revisions[card.id]!, content: "第一次修改")])])

        await rejected(fixture.toolbox, "update_cards", ["updates": .array([update(card, revision: revisions[card.id]!, content: "使用旧版本的第二次修改")])])

        #expect(card.content == "第一次修改")
        #expect(fixture.changeCount == 1)
    }

    @Test func successfulMergeCanBeUndoneWithoutLosingOriginalCardsAndLinks() async throws {
        let fixture = try LibraryToolboxFixture()
        let first = fixture.card("第一卡")
        let second = fixture.card("第二卡")
        fixture.context.insert(ConceptLink(from: first.id, to: second.id, kind: .contrast, reason: "原关联", isManual: true))
        try fixture.context.save()
        let before = try LibraryAssistantSnapshot(context: fixture.context)
        let revisions = try await readCards(fixture.toolbox, [first, second])
        _ = try await execute(fixture.toolbox, "merge_cards", merge([first, second], revisions: revisions))
        let change = try #require(fixture.changes.last)

        try change.undo(in: fixture.context)

        #expect(try LibraryAssistantSnapshot(context: ModelContext(fixture.container)) == before)
    }

    @Test func undoDoesNotOverwriteLaterUserEdits() async throws {
        let fixture = try LibraryToolboxFixture()
        let card = fixture.card("原卡")
        try fixture.context.save()
        let revisions = try await readCards(fixture.toolbox, [card])
        _ = try await execute(fixture.toolbox, "update_cards", ["updates": .array([update(card, revision: revisions[card.id]!, content: "助手修改")])])
        let change = try #require(fixture.changes.last)
        card.content = "用户后续修改"
        try fixture.context.save()

        #expect(throws: LibraryAssistantChange.UndoError.changedSinceOperation) { try change.undo(in: fixture.context) }

        #expect(card.content == "用户后续修改")
    }

    @Test func cardAndNoteListsFilterAndPaginateWithoutExposingAReadRevision() async throws {
        let fixture = try LibraryToolboxFixture()
        let first = fixture.card("导数定义")
        first.createdAt = Date(timeIntervalSince1970: 1)
        let second = fixture.card("导数应用")
        second.createdAt = Date(timeIntervalSince1970: 2)
        _ = fixture.card("导数在物理中的应用", subject: .physics)
        let firstNote = fixture.note("导数资料一")
        firstNote.createdAt = Date(timeIntervalSince1970: 1)
        let secondNote = fixture.note("导数资料二")
        secondNote.createdAt = Date(timeIntervalSince1970: 2)
        try fixture.context.save()

        let cards = try await execute(fixture.toolbox, "list_cards", ["query": "导数", "subject": "数学", "offset": 1, "limit": 1])
        #expect(cards["total"] == 2 && cards["next_offset"] == .null)
        let listedCard = try #require(cards["cards"]?.arrayValue?.first)
        #expect(listedCard["id"]?.stringValue == second.id.uuidString)
        #expect(listedCard["revision"] == nil && listedCard["content"] == nil)
        let notes = try await execute(fixture.toolbox, "list_notes", ["query": "导数资料", "offset": 0, "limit": 1])
        #expect(notes["total"] == 2 && notes["next_offset"] == 1)
        let listedNote = try #require(notes["notes"]?.arrayValue?.first)
        #expect(listedNote["id"]?.stringValue == firstNote.id.uuidString)
        #expect(listedNote["revision"] == nil && listedNote["content"] == nil)
        #expect(fixture.changeCount == 0)
    }

    @Test func organizingAnAlreadySplitNoteDoesNotDuplicateCardsOrDeleteItsOriginal() async throws {
        let fixture = try LibraryToolboxFixture()
        let note = fixture.note()
        let card = fixture.card("已经整理过的卡")
        card.noteID = note.id
        try fixture.context.save()
        let result = try await execute(fixture.toolbox, "read_note", ["id": .string(note.id.uuidString)])
        let revision = try #require(result["note"]?["revision"]?.stringValue)

        await rejected(fixture.toolbox, "organize_note", organize(note, revision: revision))

        #expect(try fixture.context.fetchCount(FetchDescriptor<ResearchNote>()) == 1)
        #expect(try fixture.context.fetchCount(FetchDescriptor<ConceptCard>()) == 1)
        #expect(card.title == "已经整理过的卡")
        #expect(fixture.changeCount == 0)
    }

    @Test func cancellationBeforeExecutionCannotWriteAnything() async throws {
        let fixture = try LibraryToolboxFixture()
        let card = fixture.card("原卡")
        try fixture.context.save()
        let revisions = try await readCards(fixture.toolbox, [card])
        let input: JSONValue = ["updates": .array([update(card, revision: revisions[card.id]!, content: "取消后不应写入")])]
        let request = call("update_cards", input)
        let task = Task { @MainActor in
            withUnsafeCurrentTask { $0?.cancel() }
            return try await fixture.toolbox.execute(request)
        }

        await #expect(throws: CancellationError.self) { try await task.value }

        #expect(card.content == "完整定义与条件。")
        #expect(fixture.changeCount == 0)
    }
}
