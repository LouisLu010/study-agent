import Foundation
import Testing
@testable import StudyKit

@Suite struct ConceptCardWriterTests {
    let a = WebSource(url: "https://a.example/x", title: "A")
    let b = WebSource(url: "https://b.example/y", title: "B")

    let raw = """
    ```json
    {
      "title": "导数和极值",
      "subject": "数学",
      "topic": "导数的应用",
      "cards": [
        {"key": "c1", "title": "导数的定义", "content": "函数在一点的导数是平均变化率的极限 [2]。", "example": ""},
        {"key": "c2", "title": "用导数求极值", "content": "极值点处导数为 0，且两侧导数变号。", "example": "$f(x)=x^3-3x$ 在 $x=\\\\pm1$ 取极值。"},
        {"key": "c3", "title": "", "content": "没有标题的卡要丢掉"}
      ],
      "links": [
        {"from": "c1", "to": "c2", "kind": "prerequisite", "reason": "求极值要先会求导"},
        {"from": "旧2", "to": "c2", "kind": "对比", "reason": "极值和最值容易混"},
        {"from": "旧1", "to": "旧2", "kind": "contrast", "reason": "旧卡之间不要"},
        {"from": "c1", "to": "c9", "kind": "application", "reason": "指向不存在的卡"},
        {"from": "c2", "to": "旧7", "kind": "application", "reason": "超出候选"},
        {"from": "c1", "to": "c2", "kind": "causes", "reason": "种类不对"}
      ]
    }
    ```
    """

    @Test func parsesCardsAndLinks() throws {
        let draft = try ConceptCardWriter.parse(raw, sources: [a, b], candidateCount: 3, fallbackTitle: "会话")
        #expect(draft.title == "导数和极值")
        #expect(draft.subject == .math)
        #expect(draft.cards.map(\.title) == ["导数的定义", "用导数求极值"])
        #expect(draft.cards[1].example.contains("x^3"))
        #expect(draft.links == [
            .init(from: .new(0), to: .new(1), kind: .prerequisite, reason: "求极值要先会求导"),
            .init(from: .old(1), to: .new(1), kind: .contrast, reason: "极值和最值容易混"),
        ])
    }

    @Test func eachCardKeepsOnlyItsOwnSources() throws {
        let draft = try ConceptCardWriter.parse(raw, sources: [a, b], candidateCount: 3, fallbackTitle: "会话")
        #expect(draft.cards[0].sources == [b])
        #expect(draft.cards[0].content.contains("[[1]](<https://b.example/y>)"))
        #expect(draft.cards[1].sources.isEmpty)
    }

    @Test func reportsWhyItFailed() {
        #expect(throws: ConceptCardWriter.ParseError.self) {
            try ConceptCardWriter.parse("好的，下面是资料", sources: [], candidateCount: 0, fallbackTitle: "x")
        }
        do {
            _ = try ConceptCardWriter.parse("```json\n{\"cards\": [{\"title\": \"a\" \"content\": \"b\"}]}\n```", sources: [], candidateCount: 0, fallbackTitle: "x")
            Issue.record("应该报错")
        } catch let error as ConceptCardWriter.ParseError {
            #expect(error.message.hasPrefix("JSON 格式有误"))
        } catch {
            Issue.record("错误类型不对")
        }
    }

    @Test func capsAtTenCards() throws {
        let cards = (1...14).map { #"{"key":"c\#($0)","title":"卡\#($0)","content":"内容"}"# }.joined(separator: ",")
        let draft = try ConceptCardWriter.parse(#"{"cards":[\#(cards)]}"#, sources: [], candidateCount: 0, fallbackTitle: "默认标题")
        #expect(draft.cards.count == 10)
        #expect(draft.title == "默认标题")
    }

    @Test func candidatesPreferSameTopicThenRecent() {
        let now = Date()
        let many = (0..<100).map { i in
            ConceptCardWriter.Candidate(id: UUID(), title: "卡\(i)", subject: .math, topic: i % 10 == 0 ? "导数" : "其他", updatedAt: now - Double(i))
        }
        let picked = ConceptCardWriter.selectCandidates(many, topic: "导数")
        #expect(picked.count == ConceptCardWriter.candidateLimit)
        #expect(picked.prefix(10).allSatisfy { $0.topic == "导数" })
        let physics = ConceptCardWriter.selectCandidates(many, subject: .physics)
        #expect(physics.isEmpty)
        let message = ConceptCardWriter.message(material: "材料", candidates: Array(many.prefix(2)))
        #expect(message.contains("旧1 卡0（数学 · 导数）"))
        #expect(message.contains("旧2 卡1（数学 · 其他）"))
    }
}
