import Foundation
import Testing
@testable import StudyKit

@Suite struct ResearchNoteWriterTests {
    private let a = WebSource(url: "https://a.com/1", title: "A")
    private let b = WebSource(url: "https://b.com/2", title: "B")
    private let c = WebSource(url: "https://c.com/3", title: "C")

    @Test func preparesTranscriptWithUnifiedNumbers() {
        let prepared = ResearchNoteWriter.prepare([
            .init(role: .user, content: "2026 年报名人数？"),
            .init(role: .assistant, content: "1290 万。[[1]](<https://b.com/2>)", sources: [b]),
            .init(role: .assistant, content: "比去年少。[[1]](<https://a.com/1>)[[2]](<https://b.com/2>)", sources: [a, b]),
            .init(role: .user, content: "  "),
        ])
        #expect(prepared.sources == [b, a])
        #expect(prepared.text == """
        【提问】
        2026 年报名人数？

        【回答】
        1290 万。[1]

        【回答】
        比去年少。[2][1]

        【出处列表】
        [1] B https://b.com/2
        [2] A https://a.com/1
        """)
    }

    @Test func parsesHeaderAndCitesInReadingOrder() {
        let raw = """
        标题：2026 高考报名人数
        科目：其他
        知识点：高考概况
        ---
        # 2026 高考报名人数

        今年 1290 万[2]，比去年少 45 万[1][2]。
        公式 $a[1]$ 和代码不动：
        ```
        x[1]
        ```
        """
        let draft = ResearchNoteWriter.parse(raw, sources: [a, b, c], fallbackTitle: "会话")
        #expect(draft.title == "2026 高考报名人数")
        #expect(draft.subject == .other)
        #expect(draft.topic == "高考概况")
        #expect(draft.sources == [b, a])
        #expect(draft.content == """
        今年 1290 万[[1]](<https://b.com/2>)，比去年少 45 万[[2]](<https://a.com/1>)[[1]](<https://b.com/2>)。
        公式 $a[1]$ 和代码不动：
        ```
        x[1]
        ```
        """)
    }

    @Test func fallsBackWhenFormatIsMissing() {
        let draft = ResearchNoteWriter.parse("只有正文。", sources: [a], fallbackTitle: "会话标题")
        #expect(draft.title == "会话标题")
        #expect(draft.subject == nil)
        #expect(draft.content == "只有正文。")
        // 没有引用时保留全部出处。
        #expect(draft.sources == [a])
    }

    @Test func removesSourceAndRenumbers() {
        let content = "甲[[1]](<https://a.com/1>)乙[[2]](<https://b.com/2>)丙[[3]](<https://c.com/3>)[[1]](<https://a.com/1>)"
        let result = ResearchNoteWriter.removeSource(at: 0, sources: [a, b, c], content: content)
        #expect(result.sources == [b, c])
        #expect(result.content == "甲乙[[1]](<https://b.com/2>)丙[[2]](<https://c.com/3>)")
    }

    @Test(arguments: [
        "$$\na[1]+b[2]\n$$",
        "\\[\n矩阵😀 a[1]+b[2]\n\\]",
        "\\(a[1]+b[2]\\)",
        "$a[1]+b[2]$",
        "`a[1]` 和 ``b[2] + `text``",
        "````swift\nlet a = [1]\n```\nb[2]\n````",
        "~~~text\n[1]\n```\n[2]\n~~~",
    ])
    func preservesMathAndCodeBeforeCitations(_ protected: String) {
        let body = protected + "\n正文😀[2][1][2]。"
        let result = ResearchNoteWriter.citeSources(in: body, sources: [a, b])
        #expect(result.content == protected + "\n正文😀[[1]](<https://b.com/2>)[[2]](<https://a.com/1>)[[1]](<https://b.com/2>)。")
        #expect(result.sources == [b, a])
    }

    @Test(arguments: ["$$\na[1]", "\\[\na[1]", "~~~\na[1]", "````\na[1]\n```\nb[2]"])
    func preservesUnclosedBlocks(_ body: String) {
        let result = ResearchNoteWriter.citeSources(in: body, sources: [a, b])
        #expect(result.content == body)
        #expect(result.sources == [a, b])
    }

    @Test func currencyDoesNotHideFollowingCitations() {
        let result = ResearchNoteWriter.citeSources(in: #"价格 $5 和 $10，转义 \$5[2]。"#, sources: [a, b])
        #expect(result.content == #"价格 $5 和 $10，转义 \$5[[1]](<https://b.com/2>)。"#)
        #expect(result.sources == [b])
    }

    @Test func removingSourcesPreservesLiteralMarkersInCodeAndMath() {
        let marker = "[[1]](<https://a.com/1>)"
        let protected = "`\(marker)`\n$$\n\(marker)\n$$\n~~~\n\(marker)\n~~~"
        let result = ResearchNoteWriter.removeSource(at: 0, sources: [a], content: protected + "\n正文" + marker)
        #expect(result.content == protected + "\n正文")
        #expect(result.sources.isEmpty)
    }

    @Test func preparingTranscriptKeepsLiteralCodeMarkers() {
        let marker = "[[1]](<https://a.com/1>)"
        let prepared = ResearchNoteWriter.prepare([.init(role: .assistant, content: "`\(marker)`\n正文" + marker, sources: [a])])
        #expect(prepared.text.contains("`\(marker)`\n正文[1]"))
    }
}
