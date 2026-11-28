import Foundation
import StudyKit
import SwiftData

/// 首版只读。每次查询重新取本机记录，已删除或等待删除的内容不会继续返回。
@MainActor
final class StudyAssistantToolbox {
    private let context: ModelContext
    private let conversationID: UUID?
    private let hiddenIDs: @MainActor () -> Set<PersistentIdentifier>
    private(set) var references: [StudyReference]
    private var resultBytes = 0

    init(context: ModelContext, conversationID: UUID? = nil, references: [StudyReference] = [],
         hiddenIDs: @escaping @MainActor () -> Set<PersistentIdentifier> = { [] }) {
        self.context = context
        self.conversationID = conversationID
        self.references = references
        self.hiddenIDs = hiddenIDs
    }

    func execute(_ call: ToolCall) async throws -> ToolLoop.Outcome {
        try Task.checkCancellation()
        let value: JSONValue
        let previousReferences = references
        switch try StudyAssistantTools.parse(call) {
        case let .search(kind, query, subject, since, offset, limit):
            value = try search(kind: kind, query: query, subject: subject, since: since, offset: offset, limit: limit)
        case let .read(kind, id, offset, limit):
            value = try read(kind: kind, id: id, offset: offset, limit: limit)
        }
        try Task.checkCancellation()
        let content = value.jsonString
        guard resultBytes + content.utf8.count <= StudyAssistantTools.maxToolBytes else {
            references = previousReferences
            return ToolLoop.Outcome(["error": "本轮读取内容已达到上限，请缩小问题范围。"], stop: true)
        }
        resultBytes += content.utf8.count
        return ToolLoop.Outcome(content: content)
    }

    private func search(kind: StudyRecordKind?, query: String, subject: Subject?, since: Date?, offset: Int, limit: Int) throws -> JSONValue {
        var matches: [(record: StudyRecord, snippet: String, readOffset: Int)] = []
        let hidden = hiddenIDs()
        for kind in kind.map({ [$0] }) ?? StudyRecordKind.allCases {
            for record in try StudyRecordStore.all(kind, in: context) {
                try Task.checkCancellation()
                guard record.isAvailable(hiddenIDs: hidden, excluding: conversationID) else { continue }
                if let since, record.date < since { continue }
                let text = record.text
                if let subject {
                    if kind == .conversation {
                        guard (record.title + "\n" + text).localizedStandardContains(subject.rawValue) else { continue }
                    } else if (record.subject.isEmpty ? Subject.other.rawValue : record.subject) != subject.rawValue { continue }
                }
                let range = query.isEmpty ? nil : text.range(of: query, options: [.caseInsensitive, .diacriticInsensitive])
                guard query.isEmpty || range != nil || [record.title, record.topic].contains(where: { $0.localizedStandardContains(query) }) else { continue }
                let location = range.map { text.distance(from: text.startIndex, to: $0.lowerBound) } ?? 0
                let start = max(0, location - 80)
                matches.append((record, String(text.dropFirst(start).prefix(240)), start))
            }
        }
        matches.sort {
            if $0.record.date != $1.record.date { return $0.record.date > $1.record.date }
            return $0.record.kind.rawValue + $0.record.id.uuidString < $1.record.kind.rawValue + $1.record.id.uuidString
        }
        let page = matches.dropFirst(offset).prefix(limit).map { item -> JSONValue in
            let record = item.record
            return ["kind": .string(record.kind.rawValue), "id": .string(record.id.uuidString),
                    "title": .string(String(record.title.prefix(160))), "subject": .string(record.subject), "topic": .string(String(record.topic.prefix(160))),
                    "date": .string(record.date.ISO8601Format()), "snippet": .string(item.snippet), "read_offset": .number(Double(item.readOffset))]
        }
        let next = offset + page.count
        return ["records": .array(page), "total": .number(Double(matches.count)),
                "next_offset": next < matches.count ? .number(Double(next)) : .null]
    }

    private func read(kind: StudyRecordKind, id: UUID, offset: Int, limit: Int) throws -> JSONValue {
        guard let record = try StudyRecordStore.find(kind: kind, id: id, in: context),
              record.isAvailable(hiddenIDs: hiddenIDs(), excluding: conversationID)
        else { throw StudyAssistantTools.ArgumentError("记录不存在、已删除或不能读取，请重新查找。") }
        let text = record.text
        guard offset <= text.count else { throw StudyAssistantTools.ArgumentError("读取位置超过正文长度，请重新查找。") }
        let reference: StudyReference
        if let existing = references.first(where: { $0.kind == kind && $0.recordID == id }) {
            reference = existing
        } else {
            reference = StudyReference(number: (references.map(\.number).max() ?? 0) + 1, kind: kind, recordID: id, title: String(record.title.prefix(160)))
            references.append(reference)
        }
        let content = String(text.dropFirst(offset).prefix(limit))
        let next = offset + content.count
        return ["kind": .string(kind.rawValue), "id": .string(id.uuidString), "title": .string(reference.title),
                "citation": .string(reference.citation), "subject": .string(record.subject), "topic": .string(record.topic),
                "content": .string(content), "offset": .number(Double(offset)), "total_characters": .number(Double(text.count)),
                "next_offset": next < text.count ? .number(Double(next)) : .null]
    }
}
