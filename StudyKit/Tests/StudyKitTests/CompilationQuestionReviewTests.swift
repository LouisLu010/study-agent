import Foundation
import Testing
@testable import StudyKit

@Suite struct CompilationQuestionReviewTests {
    private let paper = PaperPlan(title: "2025 年北京卷化学", year: "2025")

    private func reply(
        _ candidate: CompilationQuestionReview.Candidate, question: [String], answer: [String] = [],
        isQuestion: Bool = true, note: String = "已核对"
    ) -> JSONValue {
        [
            "id": .string(candidate.id), "is_question": .bool(isQuestion),
            "question": .array(question.map(JSONValue.string)), "answer": .array(answer.map(JSONValue.string)), "note": .string(note),
        ]
    }

    private func response(_ items: [JSONValue]) -> String {
        JSONValue.object(["items": .array(items)]).jsonString
    }

    @Test func requestsReviewOnlyProvidedBlocksWithoutSearchOrTools() {
        let candidate = CompilationQuestionReview.Candidate(id: "Q1", number: "17", content: "题干\n![](sa-image:0)", answer: "网站答案")
        let request = CompilationQuestionReview.request(model: "deepseek-flash", paper: paper, request: "有机大题", candidates: [candidate])

        #expect(!request.webSearch)
        #expect(request.tools.isEmpty)
        #expect(request.reasoningEffort == .low)
        #expect(request.messages.count == 1)
        #expect(request.messages.first?.text.contains(paper.title) == true)
        #expect(request.messages.first?.text.contains("有机大题") == true)
        for block in candidate.blocks {
            #expect(request.messages.first?.text.contains(block.id) == true)
        }
        #expect(request.systemPrompt?.contains("不能改写") == true)
        #expect(request.systemPrompt?.contains("纯图题") == true)
        #expect(request.systemPrompt?.contains("答案会在汇编末尾") == true)
    }

    @Test func blockIDsAreStableAndSeparateCandidates() {
        let first = CompilationQuestionReview.Candidate(id: "Q1", number: "17", content: "题干\n选项", answer: "答案")
        let same = CompilationQuestionReview.Candidate(id: "Q1", number: "17", content: "题干\n选项", answer: "答案")
        let second = CompilationQuestionReview.Candidate(id: "Q2", number: "18", content: "题干\n选项", answer: "答案")

        #expect(first == same)
        #expect(first.blocks.map(\.id) == ["Q1.B1", "Q1.B2", "Q1.B3"])
        #expect(first.blocks.map(\.origin) == [.question, .question, .answer])
        #expect(Set(first.blocks.map(\.id)).isDisjoint(with: second.blocks.map(\.id)))
    }

    @Test func removesWebElementsAndMovesEmbeddedAnswersWithoutRewriting() throws {
        let candidate = CompilationQuestionReview.Candidate(
            id: "Q1", number: "17",
            content: "首页 > 试题库\n\n有机物甲的反应路线如下。\n![](sa-image:0 \"w=200,h=80\")\n（1）写出反应条件。\n【答案】加热。\n立即开通会员查看更多",
            answer: "【解析】升温可以加快反应速率。\n下载 App 查看更多题目"
        )
        let question = candidate.blocks.filter { ["有机物甲", "![]", "（1）"].contains(where: $0.text.contains) }.map(\.id)
        let answer = candidate.blocks.filter { $0.text.hasPrefix("【答案】") || $0.text.hasPrefix("【解析】") }.map(\.id)
        let result = try #require(CompilationQuestionReview.parse(response([reply(candidate, question: question, answer: answer)]), candidates: [candidate]).first)

        #expect(result.isQuestion)
        #expect(result.id == "Q1")
        #expect(result.content == "有机物甲的反应路线如下。\n![](sa-image:0 \"w=200,h=80\")\n（1）写出反应条件。")
        #expect(result.answer == "【答案】加热。\n\n【解析】升温可以加快反应速率。")
        #expect(!result.content.contains("首页"))
        #expect(!result.content.contains("会员"))
        #expect(!result.content.contains("【答案】"))
        #expect(!result.answer.contains("下载 App"))
    }

    @Test func fencedCodeIncludingBlankLinesIsOneUnchangedBlock() throws {
        let code = "```python\nif x < 2:\n    print(\"[not an image](example)\")\n\n    print(x)\n```"
        let candidate = CompilationQuestionReview.Candidate(id: "Q1", number: "1", content: "阅读程序。\n\n\(code)\n\n请选择输出结果。", answer: "")
        let block = try #require(candidate.blocks.first { $0.text.contains("```python") })

        #expect(block.text == code)
        #expect(candidate.blocks.count == 3)
        let result = try #require(CompilationQuestionReview.parse(response([reply(candidate, question: candidate.blocks.map(\.id))]), candidates: [candidate]).first)
        #expect(result.content == candidate.content)
    }

    @Test func tildeAndIndentedCodeKeepTheirInteriorSpacing() throws {
        let fenced = "~~~~text\ncode\n\nmore code\n~~~~"
        let indented = "    let x = 1\n\n    print(x)"
        let candidate = CompilationQuestionReview.Candidate(id: "Q1", number: "1", content: "\(fenced)\n\n\(indented)\n结束", answer: "")

        #expect(candidate.blocks.contains { $0.text == fenced })
        #expect(candidate.blocks.contains { $0.text == indented })
        let result = try #require(CompilationQuestionReview.parse(response([reply(candidate, question: candidate.blocks.map(\.id))]), candidates: [candidate]).first)
        #expect(result.content == candidate.content)
    }

    @Test func displayAndMultilineInlineMathCannotBeSplit() {
        let display = "$$\nf(x) = x^2\n\n+ 2x\n$$"
        let bracket = #"\["# + "\na+b\n\n=c\n" + #"\]"#
        let inline = #"已知 \(a+"# + "\nb" + #"\)，求值。"#
        let candidate = CompilationQuestionReview.Candidate(id: "Q1", number: "1", content: "条件\n\n\(display)\n\n\(bracket)\n\n\(inline)\n广告", answer: "")

        #expect(candidate.blocks.contains { $0.text == display })
        #expect(candidate.blocks.contains { $0.text == bracket })
        #expect(candidate.blocks.contains { $0.text == inline })
        #expect(candidate.blocks.last?.text == "广告")
    }

    @Test func latexEnvironmentsKeepBlankLinesAndNestedMatrixRows() {
        let formula = #"\begin{align}"# + "\nx &= " + #"\begin{matrix}"# + "\n1 & 2 " + #"\\"# + "\n3 & 4\n" + #"\end{matrix}"# + "\n\ny &= 2\n" + #"\end{align}"#
        let candidate = CompilationQuestionReview.Candidate(id: "Q1", number: "1", content: "已知\n\(formula)\n求解", answer: "")

        #expect(candidate.blocks.map(\.text) == ["已知", formula, "求解"])
    }

    @Test func aMarkdownTableIsAnIndivisibleBlock() throws {
        let table = "| 物质 | 浓度 |\n| :--- | ---: |\n| A | $0.1$ |\n| B | ![](sa-image:1) |"
        let candidate = CompilationQuestionReview.Candidate(id: "Q1", number: "17", content: "实验数据：\n\n\(table)\n\n求反应速率。", answer: "")

        #expect(candidate.blocks.map(\.text) == ["实验数据：", table, "求反应速率。"])
        let result = try #require(CompilationQuestionReview.parse(response([reply(candidate, question: candidate.blocks.map(\.id))]), candidates: [candidate]).first)
        #expect(result.content == candidate.content)
    }

    @Test func imagesAndMultilineImageTitlesRemainByteForByte() throws {
        let asset = UUID().uuidString
        let image = "![实验装置](sa-asset:\(asset)\n\"w=240,h=160\")"
        let placeholder = "![](sa-image:3 \"w=100,h=80\")"
        let candidate = CompilationQuestionReview.Candidate(id: "Q1", number: "17", content: "题干\n\(image)\n\(placeholder)\n网站页脚", answer: "")
        let selected = candidate.blocks.filter { $0.text != "网站页脚" }

        #expect(selected.contains { $0.text == image })
        #expect(selected.contains { $0.text == placeholder })
        let result = try #require(CompilationQuestionReview.parse(response([reply(candidate, question: selected.map(\.id))]), candidates: [candidate]).first)
        #expect(result.content == "题干\n\(image)\n\(placeholder)")
    }

    @Test func pureImageQuestionsCanBeKeptOrRejectedWithoutTranscription() throws {
        let candidate = CompilationQuestionReview.Candidate(id: "Q1", number: "17", content: "![](sa-image:0)", answer: "")
        let kept = try #require(CompilationQuestionReview.parse(response([reply(candidate, question: candidate.blocks.map(\.id))]), candidates: [candidate]).first)
        #expect(kept.content == candidate.content)
        let rejected = try #require(CompilationQuestionReview.parse(response([reply(candidate, question: [], isQuestion: false, note: "无法确认是题目图片")]), candidates: [candidate]).first)
        #expect(!rejected.isQuestion)
        #expect(rejected.content.isEmpty)
        #expect(rejected.answer.isEmpty)
        #expect(rejected.note == "无法确认是题目图片")
    }

    @Test func acceptsAnEmptySiteAnswerAndReturnsInputCandidateOrder() throws {
        let first = CompilationQuestionReview.Candidate(id: "Q1", number: "17", content: "第一道题", answer: "")
        let second = CompilationQuestionReview.Candidate(id: "Q2", number: "18", content: "第二道题", answer: "")
        let raw = response([reply(second, question: second.blocks.map(\.id)), reply(first, question: first.blocks.map(\.id))])
        let result = try CompilationQuestionReview.parse("```json\n\(raw)\n```", candidates: [first, second])

        #expect(result.map(\.id) == ["Q1", "Q2"])
        #expect(result.allSatisfy { $0.answer.isEmpty })
    }

    @Test func unknownCrossQuestionDuplicateAndReorderedBlocksAreRejected() {
        let first = CompilationQuestionReview.Candidate(id: "Q1", number: "17", content: "题干\n选项", answer: "答案")
        let second = CompilationQuestionReview.Candidate(id: "Q2", number: "18", content: "第二道题", answer: "")
        let cases = [
            reply(first, question: ["Q1.B99"]),
            reply(first, question: ["Q2.B1"]),
            reply(first, question: ["Q1.B1", "Q1.B1"]),
            reply(first, question: ["Q1.B2", "Q1.B1"]),
            reply(first, question: ["Q1.B1"], answer: ["Q1.B1"]),
            reply(first, question: ["Q1.B1"], answer: ["Q1.B3", "Q1.B2"]),
        ]
        for item in cases {
            #expect(throws: CompilationQuestionReview.ParseError.self) {
                try CompilationQuestionReview.parse(response([item, reply(second, question: second.blocks.map(\.id))]), candidates: [first, second])
            }
        }
    }

    @Test func everyCandidateMustHaveExactlyOneResult() {
        let first = CompilationQuestionReview.Candidate(id: "Q1", number: "17", content: "题干", answer: "")
        let second = CompilationQuestionReview.Candidate(id: "Q2", number: "18", content: "题干", answer: "")
        let item = reply(first, question: first.blocks.map(\.id))
        for items in [[], [item], [item, item]] {
            #expect(throws: CompilationQuestionReview.ParseError.self) {
                try CompilationQuestionReview.parse(response(items), candidates: [first, second])
            }
        }
        #expect(throws: CompilationQuestionReview.ParseError.self) {
            try CompilationQuestionReview.parse(response([item, item]), candidates: [first, first])
        }
        #expect(throws: CompilationQuestionReview.ParseError.self) {
            try CompilationQuestionReview.parse(response([]), candidates: [])
        }
    }

    @Test func falseQuestionsCannotKeepContentAndTrueQuestionsNeedContent() {
        let candidate = CompilationQuestionReview.Candidate(id: "Q1", number: "17", content: "网页导航", answer: "广告")
        for item in [
            reply(candidate, question: []),
            reply(candidate, question: ["Q1.B1"], isQuestion: false),
            reply(candidate, question: [], answer: ["Q1.B2"], isQuestion: false),
        ] {
            #expect(throws: CompilationQuestionReview.ParseError.self) { try CompilationQuestionReview.parse(response([item]), candidates: [candidate]) }
        }
    }

    @Test func invalidJSONMissingFieldsAndRewrittenContentFailExplicitly() {
        let candidate = CompilationQuestionReview.Candidate(id: "Q1", number: "17", content: "原题", answer: "")
        let item = reply(candidate, question: candidate.blocks.map(\.id))
        var cases = ["", "{}", "[]", "检查结果：" + response([item]), String(response([item]).dropLast())]
        for key in ["id", "is_question", "question", "answer", "note"] {
            var fields = item.objectValue!
            fields.removeValue(forKey: key)
            cases.append(response([.object(fields)]))
        }
        var rewritten = item.objectValue!
        rewritten["content"] = "模型重新写的题干"
        cases.append(response([.object(rewritten)]))
        var wrongType = item.objectValue!
        wrongType["is_question"] = "true"
        cases.append(response([.object(wrongType)]))
        for raw in cases {
            #expect(throws: CompilationQuestionReview.ParseError.self) { try CompilationQuestionReview.parse(raw, candidates: [candidate]) }
        }
    }

    @Test func multilineInlineCodeAndUnclosedFencesAreNeverPartiallySelected() {
        let inline = "计算 `a +\nb` 的值。"
        let unfinished = "```text\n原题代码\n\n尚未闭合"
        let candidate = CompilationQuestionReview.Candidate(id: "Q1", number: "17", content: "\(inline)\n页脚\n\(unfinished)", answer: "")

        #expect(candidate.blocks.map(\.text) == [inline, "页脚", unfinished])
    }

    @Test func inlineAnswersAndExplanationsBecomeSeparateOriginalBlocks() throws {
        let candidate = CompilationQuestionReview.Candidate(id: "Q1", number: "1", content: "求 x。答案：2；解析：由 x+1=3 得出。", answer: "")
        #expect(candidate.blocks.map(\.text) == ["求 x。", "答案：2；", "解析：由 x+1=3 得出。"])
        let result = try #require(CompilationQuestionReview.parse(response([reply(candidate, question: ["Q1.B1"], answer: ["Q1.B2", "Q1.B3"])]), candidates: [candidate]).first)
        #expect(result.content == "求 x。")
        #expect(result.answer == "答案：2；解析：由 x+1=3 得出。")
        #expect(result.content + result.answer == candidate.content)
        #expect(throws: CompilationQuestionReview.ParseError.self) {
            try CompilationQuestionReview.parse(response([reply(candidate, question: candidate.blocks.map(\.id))]), candidates: [candidate])
        }
    }

    @Test func inlineBracketedAndReferenceAnswersKeepWhitespaceAndMarkdown() throws {
        let candidate = CompilationQuestionReview.Candidate(id: "Q1", number: "1", content: "求 x。  **参考答案：** $2$；【解析】代入计算。", answer: "")
        #expect(candidate.blocks.map(\.text) == ["求 x。  ", "**参考答案：** $2$；", "【解析】代入计算。"])
        let result = try #require(CompilationQuestionReview.parse(response([reply(candidate, question: ["Q1.B1"], answer: ["Q1.B2", "Q1.B3"])]), candidates: [candidate]).first)
        #expect(result.content == "求 x。  ")
        #expect(result.answer == "**参考答案：** $2$；【解析】代入计算。")
    }

    @Test func answerInstructionsAndBlanksAreNotMistakenForSiteAnswers() {
        for text in ["求 x，请写出答案：____。", "答案：____", "请填写【答案】____。", "请根据以下解析：先展开括号，再计算。", "请写出答案：$x=\\underline{\\quad}$。"] {
            let candidate = CompilationQuestionReview.Candidate(id: "Q1", number: "1", content: text, answer: "")
            #expect(candidate.blocks.map(\.text) == [text])
        }
    }

    @Test func answerLabelsInsideCodeMathAndImagesAreProtected() {
        let code = "```text\n答案：2；解析：这是程序输出\n```"
        let formula = #"$$\text{答案：2；解析：文字}$$"#
        let image = "![答案：2；解析：图示](sa-image:0 \"w=200,h=100\")"
        let candidate = CompilationQuestionReview.Candidate(id: "Q1", number: "1", content: "\(code)\n\(formula)\n\(image)\n求 x。答案：3", answer: "")
        #expect(candidate.blocks.map(\.text) == [code, formula, image, "求 x。", "答案：3"])
    }

    @Test func mixedQuestionAndAnswerTablesFailInsteadOfLeakingAnswers() {
        let table = "| 原题 | 网站答案 |\n| --- | --- |\n| 求 x。 | 答案：2；解析：代入计算。 |"
        let candidate = CompilationQuestionReview.Candidate(id: "Q1", number: "1", content: table, answer: "")
        #expect(candidate.blocks.map(\.text) == [table])
        #expect(throws: CompilationQuestionReview.ParseError.self) {
            try CompilationQuestionReview.parse(response([reply(candidate, question: ["Q1.B1"])]), candidates: [candidate])
        }
    }
}
