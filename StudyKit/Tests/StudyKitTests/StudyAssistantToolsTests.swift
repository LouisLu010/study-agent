import Foundation
import Testing
@testable import StudyKit

@Suite struct StudyAssistantToolsTests {
    private var search: JSONValue {
        ["kind": "mistake", "query": "导数", "subject": "数学", "since": "2026-11-01T00:00:00+08:00", "offset": 0, "limit": 10]
    }

    private func parse(_ name: String, _ value: JSONValue) throws -> StudyAssistantTools.Action {
        try StudyAssistantTools.parse(ToolCall(id: "test", name: name, arguments: value.jsonString))
    }

    @Test func validatesKindsDatesAndBounds() throws {
        let date = try #require(ISO8601DateFormatter().date(from: "2026-11-01T00:00:00+08:00"))
        #expect(try parse("search_study_records", search) == .search(kind: .mistake, query: "导数", subject: .math, since: date, offset: 0, limit: 10))
        for kind in StudyRecordKind.allCases {
            let id = UUID()
            #expect(!kind.title.isEmpty)
            #expect(try parse("read_study_record", ["kind": .string(kind.rawValue), "id": .string(id.uuidString), "offset": 1, "limit": 8_000]) == .read(kind: kind, id: id, offset: 1, limit: 8_000))
        }
        #expect(try parse("search_study_records", ["kind": "", "query": "", "subject": "", "since": "", "offset": 0, "limit": 1]) == .search(kind: nil, query: "", subject: nil, since: nil, offset: 0, limit: 1))
    }

    @Test func rejectsMalformedMissingExtraAndWronglyTypedArguments() {
        for raw in ["", "null", "[]", "{}", "{"] {
            #expect(throws: StudyAssistantTools.ArgumentError.self) {
                try StudyAssistantTools.parse(ToolCall(id: "test", name: "search_study_records", arguments: raw))
            }
        }
        for (key, bad) in [("kind", JSONValue.string("provider")), ("subject", "未知"), ("since", "昨天"),
                           ("limit", 0), ("limit", 21), ("limit", .number(1.5)), ("offset", -1),
                           ("query", .number(3)), ("query", .string(String(repeating: "字", count: 201)))] {
            var fields = search.objectValue!
            fields[key] = bad
            #expect(throws: StudyAssistantTools.ArgumentError.self) { try parse("search_study_records", .object(fields)) }
        }
        for key in search.objectValue!.keys {
            var fields = search.objectValue!
            fields.removeValue(forKey: key)
            #expect(throws: StudyAssistantTools.ArgumentError.self) { try parse("search_study_records", .object(fields)) }
        }
        var fields = search.objectValue!
        fields["delete"] = true
        #expect(throws: StudyAssistantTools.ArgumentError.self) { try parse("search_study_records", .object(fields)) }
        #expect(throws: StudyAssistantTools.ArgumentError.self) { try parse("delete_records", search) }
        for (kind, id) in [("", UUID().uuidString), ("card", "invalid")] {
            #expect(throws: StudyAssistantTools.ArgumentError.self) {
                try parse("read_study_record", ["kind": .string(kind), "id": .string(id), "offset": 0, "limit": 100])
            }
        }
    }

    @Test func referencesRoundTripRejectDuplicatesAndFollowReplyVersions() {
        let reference = StudyReference(number: 1, kind: .card, recordID: UUID(), title: "导数")
        #expect(reference.citation == "[资料1]")
        #expect(StudyReference.decode(StudyReference.encode([reference])) == [reference])
        #expect(StudyReference.decode(StudyReference.encode([reference, reference])).isEmpty)
        #expect(StudyReference.decode("invalid").isEmpty)
        #expect(StudyReference.encode([]).isEmpty)
        #expect(StudyReference.sourceText([]).isEmpty)
        #expect(StudyReference.sourceText([reference]).contains("[资料1] 知识卡 · 导数"))
        let message = Message(role: .assistant, content: "定义 [资料1]", index: 0)
        message.studyReferences = [reference]
        #expect(message.contentWithStudySources.contains("[资料1] 知识卡 · 导数"))
        message.beginNewVersion()
        #expect(message.studyReferences.isEmpty)
        message.content = "另一种回答"
        message.status = .complete
        message.finishVersion()
        message.selectVersion(0)
        #expect(message.studyReferences == [reference])
        message.selectVersion(1)
        #expect(message.studyReferences.isEmpty)
        #expect(message.contentWithStudySources == "另一种回答")
    }

    @Test func requestPreservesCurrentInstructionAndBoundsHistory() {
        let long = String(repeating: "字", count: 10_000)
        var messages = (0..<20).map { ChatMessage(role: $0.isMultiple(of: 2) ? .user : .assistant, text: long) }
        messages.append(ChatMessage(role: .user, text: "当前要求" + long))
        let original = ChatRequest(model: "test", systemPrompt: "原提示词", messages: messages, reasoningEffort: .high, webSearch: true)
        let request = StudyAssistantTools.prepare(original, now: Date(timeIntervalSince1970: 0))
        #expect(request.tools == StudyAssistantTools.tools)
        #expect(!request.webSearch && request.reasoningEffort == .high)
        #expect(request.systemPrompt?.contains("1970-01-01T00:00:00Z") == true)
        #expect(request.systemPrompt?.hasPrefix("原提示词") == true)
        #expect(request.messages.count <= 12 && request.messages.first?.role == .user)
        #expect(request.messages.last?.text == "当前要求" + long)
        #expect(request.messages.dropLast().allSatisfy { $0.text.count <= 6_000 })
    }
}
