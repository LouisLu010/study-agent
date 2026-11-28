import Foundation
import Testing
@testable import StudyKit

@Suite struct PaperDocumentTests {
    private let url = URL(string: "https://example.com/papers/2026.html")!

    @Test func indexesAllFlatParagraphsIncludingTheEndOfALongPaper() throws {
        let questions = (1...100).map { "<p>\($0)．" + String(repeating: "这道题的正文。", count: 20) + "</p>" }.joined()
        let document = PaperDocument(html: "<title>整卷 &amp; 答案</title><main>\(questions)</main>", url: url)
        #expect(document.title == "整卷 & 答案")
        #expect(document.url == url)
        #expect(document.blocks.count == 100)
        #expect(document.blocks.first?.id == "B1")
        #expect(document.blocks.last?.id == "B100")
        #expect(document.blocks.last?.text.hasPrefix("100．") == true)
        let result = try document.extract(startID: "B100", endID: "B100").get()
        #expect(result.content == String(repeating: "这道题的正文。", count: 20))
    }

    @Test func nestedContainersKeepEachPieceOfTextAndEveryImageOnce() throws {
        let document = PaperDocument(html: """
        <article>前言<span>中的行内文字</span>
          <div><p>17．求以下函数的值。<strong>条件</strong></p>
            <div><img src="/one.png" width="100"><span>图片说明</span></div>
            <section><p>（1）求结果。</p><p>（2）说明原因。</p></section>
          </div>
          <p>18．另一道题。</p>
        </article>
        """, url: url)
        #expect(document.blocks.map(\.text) == [
            "前言中的行内文字", "17．求以下函数的值。条件", "[图]图片说明", "（1）求结果。", "（2）说明原因。", "18．另一道题。",
        ])
        let result = try document.extract(startID: "B2", endID: "B5").get()
        #expect(result.content.contains("求以下函数的值。**条件**"))
        #expect(result.content.contains("![](sa-image:0 \"w=100\")图片说明"))
        #expect(result.content.contains("（2）说明原因。"))
        #expect(!result.content.contains("前言"))
        #expect(!result.content.contains("另一道题"))
        #expect(result.imageURLs == ["https://example.com/one.png"])
    }

    @Test func tableIsAtomicAndRetainsFormulasAndImages() throws {
        let document = PaperDocument(html: """
        <p>17．完成表格。</p>
        <table><tr><th>物质</th><th>结构</th></tr>
        <tr><td>H<sub>2</sub>O</td><td><img data-src="//img.example.com/a.png" width="20" height="10"></td></tr></table>
        <p>（1）说明原因。</p>
        """, url: url)
        #expect(document.blocks.count == 3)
        #expect(document.blocks[1].text.contains("H2O"))
        #expect(document.blocks[1].text.contains("[图]"))
        let result = try document.extract(startID: "B1", endID: "B3").get()
        #expect(result.content.contains("| 物质 | 结构 |"))
        #expect(result.content.contains("H$_{2}$O"))
        #expect(result.content.contains("![](sa-image:0 \"w=20,h=10\")"))
        #expect(result.imageURLs == ["https://img.example.com/a.png"])
    }

    @Test func extractsPureEnglishWithoutChineseAnchors() throws {
        let document = PaperDocument(html: """
        <p>1. Read the text and answer the question.</p>
        <div><p>Tom took a train to London.</p><p>Where did Tom go?</p></div>
        <p>2. Choose the right word.</p>
        """, url: url)
        let result = try document.extract(startID: "B1", endID: "B3").get()
        #expect(result.content.contains("Read the text"))
        #expect(result.content.contains("Where did Tom go?"))
        #expect(!result.content.contains("Choose the right word"))
        #expect(result.questionLength == 0)
    }

    @Test func separatesSiteAnswersAndKeepsAnswerImages() throws {
        let document = PaperDocument(html: """
        <p>17．根据图示回答。</p><p><img src="question.png"></p>
        <p>【答案】答案内容<img src="answer.png"></p><p>【解析】解析内容。</p>
        """, url: url)
        let result = try document.extract(startID: "B1", endID: "B4").get()
        #expect(result.content.contains("根据图示回答"))
        #expect(!result.content.contains("答案内容"))
        #expect(result.answer.contains("答案内容![](sa-image:1)"))
        #expect(result.answer.contains("【解析】解析内容"))
        #expect(result.imageURLs == ["https://example.com/papers/question.png", "https://example.com/papers/answer.png"])
    }

    @Test func preservesGaotuAnswerStructureAcrossNestedBlocks() throws {
        let document = PaperDocument(html: """
        <div><p>17．物质的结构如下。</p><p><img src="route.png"></p>
          <div><div><p>写出官能团。</p></div><div>[["<p>羟基</p>"]]</div><div><p>解析一。</p></div></div>
          <div><div><p>写出反应类型。</p></div><div>[["<p>加成</p>"]]</div><div><p>解析二。</p></div></div>
        </div>
        """, url: url)
        let result = try document.extract(startID: "B1", endID: document.blocks.last!.id).get()
        #expect(result.content.contains("(1) 写出官能团。"))
        #expect(result.content.contains("(2) 写出反应类型。"))
        #expect(result.answer.contains("羟基"))
        #expect(result.answer.contains("加成"))
        #expect(!result.content.contains("解析一"))
    }

    @Test func groupKeepsSharedReadingMaterialAndAllQuestions() throws {
        let passage = String(repeating: "这是一段需要随题保存的阅读材料。", count: 130)
        let document = PaperDocument(html: """
        <p>阅读下面的文字，完成 18～20 题。</p><p>\(passage)</p>
        <p>18．回答问题。</p><p>19．解释原因。</p><p>20．概括主旨。</p>
        """, url: url)
        #expect(document.extract(startID: "B1", endID: "B5") == .failure(.tooLong))
        let result = try document.extract(startID: "B1", endID: "B5", group: true).get()
        #expect(result.content.contains(passage))
        #expect(result.content.contains("20．概括主旨。"))
    }

    @Test func rejectsInvalidReversedEmptyAndWholePaperRanges() {
        let document = PaperDocument(html: "<p>1．第一题。</p><p>2．第二题。</p>", url: url)
        #expect(document.extract(startID: "B0", endID: "B1") == .failure(.notFound))
        #expect(document.extract(startID: "B1", endID: "B999") == .failure(.notFound))
        #expect(document.extract(startID: "B2", endID: "B1") == .failure(.notFound))
        #expect(document.extract(startID: "B1", endID: "B2") == .failure(.tooLong))
        let empty = PaperDocument(html: "<div> </div><script>hidden()</script>", url: url)
        #expect(empty.blocks.isEmpty)
        #expect(empty.extract(startID: "B1", endID: "B1") == .failure(.notFound))
        let answers = PaperDocument(html: "<p>【答案】只有答案</p>", url: url)
        #expect(answers.extract(startID: "B1", endID: "B1") == .failure(.notFound))
    }

    @Test func decimalValuesDoNotCreateQuestionBoundaries() throws {
        let document = PaperDocument(html: """
        <p>17．将溶液稀释。</p>
        <p>1.0 mol/L 的溶液取 10 mL。</p>
        <p>18.5 mL 水加入后，计算浓度。</p>
        """, url: url)
        let result = try document.extract(startID: "B1", endID: "B3").get()
        #expect(result.content.contains("1.0 mol/L"))
        #expect(result.content.contains("18.5 mL"))
    }

    @Test func lowerStepNumbersStayWithTheirMainQuestion() throws {
        let document = PaperDocument(html: """
        <p>17．完成以下实验。</p><p>1. 加水。</p><p>2. 加热。</p>
        <p>18．另一道实验题。</p>
        """, url: url)
        let result = try document.extract(startID: "B1", endID: "B3").get()
        #expect(result.content.contains(#"1\. 加水。"#))
        #expect(result.content.contains(#"2\. 加热。"#))
        #expect(document.extract(startID: "B1", endID: "B4") == .failure(.tooLong))
        let adjacent = PaperDocument(html: "<p>17．实验甲。</p><p>18．实验乙。</p>", url: url)
        #expect(adjacent.extract(startID: "B1", endID: "B2") == .failure(.tooLong))
    }

    @Test func rejectsMultipleQuestionsInsideOneAtomicBlock() {
        for html in [
            "<p>17．实验甲。<br>18．实验乙。</p>",
            "<table><tr><td>17．实验甲。</td></tr><tr><td>18．实验乙。</td></tr></table>",
        ] {
            let document = PaperDocument(html: html, url: url)
            #expect(document.blocks.count == 1)
            #expect(document.extract(startID: "B1", endID: "B1") == .failure(.tooLong))
        }
    }

    @Test func lineBreaksPreserveStepsAndDecimalTableValues() throws {
        let document = PaperDocument(html: """
        <p>17．完成以下实验。<br>1. 加水。<br>2. 加热。<br>18.5 mL 溶液的浓度是多少？</p>
        <table><tr><th>体积</th><th>温度</th></tr><tr><td>19.5</td><td>20.5</td></tr></table>
        """, url: url)
        let result = try document.extract(startID: "B1", endID: "B2").get()
        #expect(result.content.contains(#"1\. 加水。"#))
        #expect(result.content.contains(#"2\. 加热。"#))
        #expect(result.content.contains("18.5 mL"))
        #expect(result.content.contains("19.5"))
    }

    @Test func rejectsOversizedChineseAndEnglishRanges() {
        let chinese = PaperDocument(html: "<p>" + String(repeating: "题", count: 1801) + "</p>", url: url)
        #expect(chinese.extract(startID: "B1", endID: "B1") == .failure(.tooLong))
        let english = PaperDocument(html: "<p>" + String(repeating: "word ", count: 4000) + "</p>", url: url)
        #expect(english.extract(startID: "B1", endID: "B1") == .failure(.tooLong))
        let group = PaperDocument(html: "<p>" + String(repeating: "word ", count: 11000) + "</p>", url: url)
        #expect(group.extract(startID: "B1", endID: "B1", group: true) == .failure(.tooLong))
    }

    @Test func collectsOnlyRealDownloadableLinksAndDeduplicatesFragments() {
        let document = PaperDocument(html: """
        <a href="../q/17#answer">第 17 题</a>
        <a href="https://example.com/q/17#question">重复</a>
        <a href="//zujuan.21cnjy.com/question/detail/123">第 18 题</a>
        <a href="http://other.example.com/19" title="第 19 题"><img src="icon.png"></a>
        <a href="#top">页内</a><a href="javascript:alert(1)">脚本</a>
        <a href="mailto:a@example.com">邮箱</a><a href="file:///tmp/q">本地</a>
        <a href="https://user:secret@example.com/q">带凭据</a>
        <a href="https://zujuan.xkw.com/14q1.html">已知打不开</a>
        """, url: url)
        #expect(document.links.map(\.id) == ["L1", "L2", "L3"])
        #expect(document.links.map(\.title) == ["第 17 题", "第 18 题", "第 19 题"])
        #expect(document.links.map(\.url) == [
            "https://example.com/q/17", "https://zujuan.21cnjy.com/question/detail/123", "https://other.example.com/19",
        ])
    }
}
