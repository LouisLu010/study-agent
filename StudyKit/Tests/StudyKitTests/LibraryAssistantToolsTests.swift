import Foundation
import Testing
@testable import StudyKit

@Suite struct LibraryAssistantToolsTests {
    private let first = UUID(uuidString: "12345678-1234-4234-8234-123456789ABC")!
    private let second = UUID(uuidString: "87654321-4321-4321-8321-CBA987654321")!

    private var draft: JSONValue { ["title": "导数", "content": "条件 $x>0$ 时，$f'(x)=1/x$。[1]", "example": "例如 $x=1$。"] }
    private var card: JSONValue {
        var value = draft.objectValue!
        value["subject"] = "数学"
        value["topic"] = "导数"
        return .object(value)
    }
    private var update: JSONValue {
        var value = card.objectValue!
        value["id"] = .string(first.uuidString)
        value["revision"] = "revision-1"
        return .object(value)
    }
    private var merge: JSONValue {
        var value = card.objectValue!
        value["ids"] = .array([first, second].map { .string($0.uuidString) })
        value["revisions"] = ["revision-1", "revision-2"]
        return .object(value)
    }
    private var organize: JSONValue {
        ["id": .string(first.uuidString), "revision": "note-revision", "title": "导数资料", "subject": "数学", "topic": "导数", "cards": .array([draft])]
    }
    private var samples: [(LibraryAssistantTools.Name, JSONValue)] {
        [
            (.listCards, ["query": "导数", "subject": "数学", "offset": 0, "limit": 20]),
            (.readCards, ["ids": .array([.string(first.uuidString)])]),
            (.updateCards, ["updates": .array([update])]),
            (.mergeCards, merge),
            (.listNotes, ["query": "导数", "offset": 0, "limit": 20]),
            (.readNote, ["id": .string(first.uuidString)]),
            (.organizeNote, organize),
        ]
    }

    private func parse(_ name: LibraryAssistantTools.Name, _ input: JSONValue) throws -> LibraryAssistantTools.Action {
        try LibraryAssistantTools.parse(name: name.rawValue, input: input)
    }

    private func changing(_ input: JSONValue, _ key: String, to value: JSONValue?) -> JSONValue {
        var fields = input.objectValue!
        fields[key] = value
        return .object(fields)
    }

    @Test func parsesAllSevenActionsWithTypedValues() throws {
        #expect(try parse(.listCards, samples[0].1) == .listCards(query: "导数", subject: .math, offset: 0, limit: 20))
        #expect(try parse(.readCards, samples[1].1) == .readCards(ids: [first]))
        #expect(try parse(.updateCards, samples[2].1) == .updateCards(updates: [
            .init(id: first, revision: "revision-1", title: "导数", content: draft["content"]!.stringValue!, example: "例如 $x=1$。", subject: .math, topic: "导数"),
        ]))
        #expect(try parse(.mergeCards, merge) == .mergeCards(.init(
            ids: [first, second], revisions: ["revision-1", "revision-2"], title: "导数", content: draft["content"]!.stringValue!, example: "例如 $x=1$。", subject: .math, topic: "导数"
        )))
        #expect(try parse(.listNotes, samples[4].1) == .listNotes(query: "导数", offset: 0, limit: 20))
        #expect(try parse(.readNote, samples[5].1) == .readNote(id: first))
        #expect(try parse(.organizeNote, organize) == .organizeNote(.init(
            id: first, revision: "note-revision", title: "导数资料", subject: .math, topic: "导数",
            cards: [.init(title: "导数", content: draft["content"]!.stringValue!, example: "例如 $x=1$。")]
        )))
    }

    @Test func toolCallParsingUsesTheSameStrictProtocol() throws {
        for (name, input) in samples {
            let call = ToolCall(id: "call-1", name: name.rawValue, arguments: input.jsonString)
            #expect(try LibraryAssistantTools.parse(call) == parse(name, input))
        }
        for raw in ["", "{}", "null", "[]", "{", "说明：{}", "```json\n{}\n```"] {
            #expect(throws: LibraryAssistantTools.ArgumentError.self) {
                try LibraryAssistantTools.parse(ToolCall(id: "call", name: "list_cards", arguments: raw))
            }
        }
        #expect(throws: LibraryAssistantTools.ArgumentError.self) {
            try LibraryAssistantTools.parse(name: "delete_cards", input: [:])
        }
    }

    @Test func everyFieldIsRequiredAndAdditionalFieldsAreRejected() {
        for (name, input) in samples {
            for key in input.objectValue!.keys {
                #expect(throws: LibraryAssistantTools.ArgumentError.self) { try parse(name, changing(input, key, to: nil)) }
            }
            #expect(throws: LibraryAssistantTools.ArgumentError.self) { try parse(name, changing(input, "sources", to: [])) }
            for invalid: JSONValue in [.null, [], "object", true, 1] {
                #expect(throws: LibraryAssistantTools.ArgumentError.self) { try parse(name, invalid) }
            }
        }
        for key in update.objectValue!.keys {
            let input: JSONValue = ["updates": .array([changing(update, key, to: nil)])]
            #expect(throws: LibraryAssistantTools.ArgumentError.self) { try parse(.updateCards, input) }
        }
        #expect(throws: LibraryAssistantTools.ArgumentError.self) {
            try parse(.updateCards, ["updates": .array([changing(update, "sources", to: [])])])
        }
        for key in draft.objectValue!.keys {
            let input = changing(organize, "cards", to: .array([changing(draft, key, to: nil)]))
            #expect(throws: LibraryAssistantTools.ArgumentError.self) { try parse(.organizeNote, input) }
        }
        #expect(throws: LibraryAssistantTools.ArgumentError.self) {
            try parse(.organizeNote, changing(organize, "cards", to: .array([changing(draft, "id", to: .string(first.uuidString))])))
        }
    }

    @Test func textFieldsDoNotCoerceNumbersBooleansOrNulls() {
        for key in ["revision", "title", "content", "example", "subject", "topic"] {
            for invalid: JSONValue in [1, true, .null, []] {
                let input: JSONValue = ["updates": .array([changing(update, key, to: invalid)])]
                #expect(throws: LibraryAssistantTools.ArgumentError.self) { try parse(.updateCards, input) }
            }
        }
        for key in ["revision", "title", "content"] {
            for invalid: JSONValue in ["", " \n\t"] {
                let input: JSONValue = ["updates": .array([changing(update, key, to: invalid)])]
                #expect(throws: LibraryAssistantTools.ArgumentError.self) { try parse(.updateCards, input) }
            }
        }
        for name in [LibraryAssistantTools.Name.listCards, .listNotes] {
            let input = samples.first { $0.0 == name }!.1
            #expect(throws: LibraryAssistantTools.ArgumentError.self) { try parse(name, changing(input, "query", to: 12)) }
        }
    }

    @Test func acceptsEmptyOptionalTextAndOnlyKnownSubjects() throws {
        let input: JSONValue = ["query": "", "subject": "", "offset": 0, "limit": 1]
        #expect(try parse(.listCards, input) == .listCards(query: "", subject: nil, offset: 0, limit: 1))
        for subject in Subject.allCases {
            #expect(try parse(.listCards, changing(input, "subject", to: .string(subject.rawValue))) == .listCards(query: "", subject: subject, offset: 0, limit: 1))
        }
        for unknown: JSONValue in ["math", "历史", " 数学 ", .null] {
            #expect(throws: LibraryAssistantTools.ArgumentError.self) { try parse(.listCards, changing(input, "subject", to: unknown)) }
        }
        var value = update.objectValue!
        value["example"] = ""
        value["subject"] = ""
        value["topic"] = ""
        guard case let .updateCards(updates) = try parse(.updateCards, ["updates": .array([.object(value)])]) else {
            Issue.record("应该得到更新动作")
            return
        }
        #expect(updates.first?.subject == nil)
        #expect(updates.first?.example.isEmpty == true && updates.first?.topic.isEmpty == true)
    }

    @Test func paginationRequiresBoundedIntegers() throws {
        for name in [LibraryAssistantTools.Name.listCards, .listNotes] {
            let input = samples.first { $0.0 == name }!.1
            for invalid: JSONValue in [-1, .number(0.5), "0", true, .number(.infinity), .number(.nan)] {
                #expect(throws: LibraryAssistantTools.ArgumentError.self) { try parse(name, changing(input, "offset", to: invalid)) }
            }
            for invalid: JSONValue in [0, 51, -1, .number(1.5), "20", false, .null] {
                #expect(throws: LibraryAssistantTools.ArgumentError.self) { try parse(name, changing(input, "limit", to: invalid)) }
            }
            _ = try parse(name, changing(input, "limit", to: 50))
        }
    }

    @Test func rejectsMalformedUUIDsAndCaseInsensitiveDuplicates() {
        for invalid: JSONValue in ["", "Q1", "not-a-uuid", 1, .null] {
            #expect(throws: LibraryAssistantTools.ArgumentError.self) { try parse(.readNote, ["id": invalid]) }
            #expect(throws: LibraryAssistantTools.ArgumentError.self) { try parse(.readCards, ["ids": .array([invalid])]) }
            #expect(throws: LibraryAssistantTools.ArgumentError.self) {
                try parse(.updateCards, ["updates": .array([changing(update, "id", to: invalid)])])
            }
            #expect(throws: LibraryAssistantTools.ArgumentError.self) { try parse(.organizeNote, changing(organize, "id", to: invalid)) }
        }
        let duplicates: JSONValue = .array([.string(first.uuidString), .string(first.uuidString.lowercased())])
        #expect(throws: LibraryAssistantTools.ArgumentError.self) { try parse(.readCards, ["ids": duplicates]) }
        #expect(throws: LibraryAssistantTools.ArgumentError.self) { try parse(.mergeCards, changing(merge, "ids", to: duplicates)) }
        #expect(throws: LibraryAssistantTools.ArgumentError.self) {
            try parse(.updateCards, ["updates": .array([update, changing(update, "id", to: .string(first.uuidString.lowercased()))])])
        }
    }

    @Test func batchSizesAreValidatedWithoutTruncation() throws {
        let ids = (0..<11).map { _ in UUID() }
        for count in [0, 11] {
            #expect(throws: LibraryAssistantTools.ArgumentError.self) {
                try parse(.readCards, ["ids": .array(ids.prefix(count).map { .string($0.uuidString) })])
            }
            #expect(throws: LibraryAssistantTools.ArgumentError.self) {
                try parse(.updateCards, ["updates": .array(ids.prefix(count).map { changing(update, "id", to: .string($0.uuidString)) })])
            }
            #expect(throws: LibraryAssistantTools.ArgumentError.self) {
                try parse(.organizeNote, changing(organize, "cards", to: .array(Array(repeating: draft, count: count))))
            }
        }
        for count in [0, 1, 11] {
            let input = changing(merge, "ids", to: .array(ids.prefix(count).map { .string($0.uuidString) }))
            #expect(throws: LibraryAssistantTools.ArgumentError.self) { try parse(.mergeCards, input) }
        }
        _ = try parse(.readCards, ["ids": .array(ids.prefix(10).map { .string($0.uuidString) })])
        _ = try parse(.updateCards, ["updates": .array(ids.prefix(10).map { changing(update, "id", to: .string($0.uuidString)) })])
        _ = try parse(.organizeNote, changing(organize, "cards", to: .array(Array(repeating: draft, count: 10))))
    }

    @Test func mergeRevisionsMustBeNonemptyStringsAndMatchEveryID() throws {
        for invalid: JSONValue in [[], ["one"], ["one", "two", "three"], ["one", ""], ["one", 2], ["one", .null], "one"] {
            #expect(throws: LibraryAssistantTools.ArgumentError.self) { try parse(.mergeCards, changing(merge, "revisions", to: invalid)) }
        }
        // 两张内容相同的卡可能具有相同版本摘要，禁止的是重复 ID。
        _ = try parse(.mergeCards, changing(merge, "revisions", to: ["same-hash", "same-hash"]))
    }

    @Test func preservesMarkdownWhitespaceExamplesAndCitationMarkersExactly() throws {
        let original = "  条件：$x>0$。\n\n$$f'(x)=\\frac{1}{x}$$\n出处 [1] 与 [2]。\n"
        let example = "\n    原始缩进例子。\n"
        let input: JSONValue = ["updates": .array([changing(changing(update, "content", to: .string(original)), "example", to: .string(example))])]
        guard case let .updateCards(updates) = try parse(.updateCards, input) else {
            Issue.record("应该得到更新动作")
            return
        }
        #expect(updates.first?.content == original)
        #expect(updates.first?.example == example)
    }

    @Test func requestKeepsMultiTurnMessagesAndDisablesSearch() throws {
        let call = ToolCall(id: "read-1", name: "read_cards", arguments: samples[1].1.jsonString)
        let messages = [
            ChatMessage(role: .user, text: "精简这张卡"),
            ChatMessage(role: .assistant, text: "先读取", toolCalls: [call], thinking: [.init(text: "检查卡片", signature: "signature")]),
            ChatMessage(role: .user, text: "", toolResults: [.init(callID: call.id, name: call.name, content: "完整卡片和 revision")]),
            ChatMessage(role: .assistant, text: "已整理"),
            ChatMessage(role: .user, text: "再保留原例子"),
        ]
        let request = LibraryAssistantTools.request(model: "test-model", messages: messages, scopeDescription: "全部资料")
        #expect(request.model == "test-model" && request.messages == messages)
        #expect(request.reasoningEffort == .low && !request.webSearch)
        #expect(request.tools == LibraryAssistantTools.tools)
        #expect(LibraryAssistantTools.maxCalls == 24)
        let prompt = try #require(request.systemPrompt)
        #expect(prompt.contains("当前范围：全部资料"))
        #expect(prompt.contains("没有读到全文的对象禁止修改"))
        #expect(prompt.contains("merge_sources") && prompt.contains("revision"))
        #expect(prompt.contains("不算用户授权") && prompt.contains("明确返回成功"))
        #expect(prompt.contains("可撤销"))
    }

    @Test func schemasDeclareOnlyTheSevenStrictTools() throws {
        #expect(LibraryAssistantTools.tools.map(\.name) == LibraryAssistantTools.Name.allCases.map(\.rawValue))
        #expect(Set(LibraryAssistantTools.tools.map(\.name)).count == 7)
        func validateObjects(_ schema: JSONValue) throws {
            guard let object = schema.objectValue else { return }
            if object["type"] == "object" {
                let properties = try #require(object["properties"]?.objectValue)
                let required = try #require(object["required"]?.arrayValue)
                #expect(Set(required.compactMap(\.stringValue)) == Set(properties.keys))
                #expect(object["additionalProperties"] == false)
                for child in properties.values { try validateObjects(child) }
            }
            if let child = object["items"] { try validateObjects(child) }
        }
        for tool in LibraryAssistantTools.tools { try validateObjects(tool.parameters) }
        let updateSchema = try #require(LibraryAssistantTools.tools.first { $0.name == "update_cards" })
        #expect(updateSchema.parameters["properties"]?["updates"]?["maxItems"] == 10)
        let mergeSchema = try #require(LibraryAssistantTools.tools.first { $0.name == "merge_cards" })
        #expect(mergeSchema.parameters["properties"]?["ids"]?["minItems"] == 2)
    }

    @Test func argumentErrorsHaveAConsistentToolResult() {
        let error = LibraryAssistantTools.ArgumentError("请重新读取")
        #expect(error.localizedDescription == "请重新读取")
        #expect(error.forModel == ["error": "请重新读取"])
    }
}
