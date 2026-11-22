import Foundation
import Testing
@testable import StudyKit

@Suite struct HTMLDocumentTests {
    @Test func parsesNestedTagsAttributesAndEntities() {
        let root = HTMLDocument.parse("""
        <html><head><title>标题</title><script>var a = "<p>";</script></head>
        <body><div class="q" data-x='1'>A&amp;B&nbsp;&#x4E2D;&#25991;<img src="a.png" width="10"><br>
        <p>一<p>二</div><!-- 注释 --></body></html>
        """)
        let divs = root.descendants().filter { $0.tag == "div" }
        #expect(divs.count == 1)
        #expect(divs[0].className == "q")
        #expect(divs[0].attributes["data-x"] == "1")
        #expect(divs[0].text.contains("A&B\u{00A0}中文"))
        #expect(root.descendants().filter { $0.tag == "p" }.count == 2)
        #expect(!root.text.contains("标题"))
        #expect(!root.text.contains("var a"))
        #expect(!root.text.contains("注释"))
        #expect(root.descendants().first { $0.tag == "img" }?.attributes["width"] == "10")
    }
}

@Suite struct QuestionExtractorTests {
    private let base = URL(string: "https://example.com/q/1")!

    /// 仿高途：题干、每一问后面跟着答案块 [["…"]] 和解析块。
    private let gaotuLike = """
    <html><body><div class="nav">一种受体拮抗剂中间体（广告）</div>
    <div class="topic">
      <div><p>一种受体拮抗剂中间体<span class="math-tk">$\\rm P$</span>合成路线如下。</p>
        <p><img width="554" height="255" src="https://cdn.example.com/route.png"></p></div>
      <div><div><p>I分子中含有的官能团是硝基和<u>&nbsp;&nbsp;&nbsp;</u>。</p></div><div></div>
        <div>[["<p><span class=\\"math-tk\\">$\\\\rm bc$</span></p>"]]</div>
        <div><p>解析一<img width=\\"98\\" height=\\"130\\" src=\\"https://cdn.example.com/a.png\\"></p></div></div>
      <div><div><p>P的合成路线中，有两处氨基的保护*。</p></div><div></div>
        <div>[["<p>E→F</p>"],["<p>Y→P</p>"]]</div>
        <div><p>解析二</p></div></div>
    </div></body></html>
    """

    @Test func extractsQuestionNumbersSubQuestionsAndSeparatesAnswers() throws {
        let result = try QuestionExtractor.extract(
            html: gaotuLike, baseURL: base, anchor: "一种受体拮抗剂中间体P合成路线", lastAnchor: "P的合成路线中，有两处"
        ).get()
        #expect(result.content == """
        一种受体拮抗剂中间体$\\rm P$合成路线如下。

        ![](sa-image:0 "w=554,h=255")

        (1) I分子中含有的官能团是硝基和＿＿＿＿＿＿。

        (2) P的合成路线中，有两处氨基的保护\\*。
        """)
        #expect(result.answer == """
        **(1) 答案** $\\rm bc$

        **解析**

        解析一![](sa-image:1 "w=98,h=130")

        **(2) 答案** E→F；Y→P

        **解析**

        解析二
        """)
        #expect(result.imageURLs == ["https://cdn.example.com/route.png", "https://cdn.example.com/a.png"])
        #expect(!result.probablyMissingImages)
    }

    /// 仿 21 世纪教育网题目详情页：网页自己的题号、选项 span、表格、要登录才能看的答案。
    @Test func handlesOptionsTablesAndLoginWall() throws {
        let html = """
        <div class="question__item"><div class="question__title">1.
        应用光化学催化可实现化合物Ⅳ的合成，示意图如图：<p><img src="//pic.example.com/1.png" width="576" height="154"></p></div>
        <div class="question__option">
        <span class="option__item"><span class="option__num">(1)</span><span class="option__meat">分子式为 <span class="filling"></span> 。</span></span>
        <span class="option__item"><span class="option__num">A.</span><span class="option__meat">有π键的断裂</span></span>
        <span class="option__item"><span class="option__num">(2)</span><span class="option__meat">完成下表。<table><tr><td>序号</td><td>新结构</td></tr><tr><td>①</td><td><img src="https://pic.example.com/2.png"></td></tr></table></span></span>
        </div><p>【答案】</p><p>您现在未登录，无法查看试题答案与解析。</p></div>
        """
        let result = try QuestionExtractor.extract(html: html, baseURL: base, anchor: "应用光化学催化", lastAnchor: "完成下表").get()
        #expect(result.content == """
        应用光化学催化可实现化合物Ⅳ的合成，示意图如图：

        ![](sa-image:0 "w=576,h=154")

        (1)分子式为 ＿＿＿＿＿＿ 。

        A.有π键的断裂

        (2)完成下表。

        | 序号 | 新结构 |
        | --- | --- |
        | ① | ![](sa-image:1) |
        """)
        #expect(result.answer.isEmpty)
        #expect(result.imageURLs == ["https://pic.example.com/1.png", "https://pic.example.com/2.png"])
    }

    @Test func rejectsWholePapersAndMissingQuestions() {
        let paper = "<div>" + String(repeating: "这是一份很长的试卷里的文字，", count: 200) + "脱落酸是一种植物激素。L→脱落酸的过程中</div>"
        #expect(QuestionExtractor.extract(html: paper, baseURL: base, anchor: "脱落酸是一种植物激素", lastAnchor: "L→脱落酸的过程中") == .failure(.tooLong))
        #expect(QuestionExtractor.extract(html: "<p>别的题</p>", baseURL: base, anchor: "脱落酸是一种植物激素", lastAnchor: "") == .failure(.notFound))
    }

    /// 语言文字运用：模型给的定位字是某道小题的题干，要把整段材料一起取下来。
    @Test func includesSharedPassageForQuestionGroups() throws {
        let html = """
        <div class="nav">语言文字应用 语言积累 词语</div>
        <div class="topic"><p>阅读下面的文字，完成各题。</p>
        <p>谐音双关是一种常见的修辞手法，即有意使用语音相同、相近而语义不同的词构成双重语义。</p>
        <p>在当代社会，谐音双关也很常见。民俗节庆文化中，常用到表示具体形象的谐音字；________。</p>
        <div class="q"><p>18．文中第二段标序号的部分有两处表述不当，请指出其序号并做修改。</p></div>
        <div class="q"><p>19．下列填入文中横线处的句子，衔接最恰当的一项是（　）</p><p>A．甲 B．乙</p></div>
        </div>
        """
        let one = try QuestionExtractor.extract(html: html, baseURL: base, anchor: "下列填入文中横线处的句子", lastAnchor: "衔接最恰当的一项是").get()
        #expect(one.content.contains("谐音双关是一种常见的修辞手法"))
        #expect(one.content.contains("下列填入文中横线处的句子"))
        #expect(!one.content.contains("语言积累"))
        let group = try QuestionExtractor.extract(
            html: html, baseURL: base, anchor: "谐音双关是一种常见的修辞手法", lastAnchor: "下列填入文中横线", group: true
        ).get()
        #expect(group.content.hasPrefix("阅读下面的文字"))
        // 普通的题不受影响：没有说到"文中"就不往外扩。
        let plain = try QuestionExtractor.extract(html: "<div><p>前言</p><p>求函数的最大值。</p></div>", baseURL: base, anchor: "求函数的最大值", lastAnchor: "").get()
        #expect(plain.content == "求函数的最大值。")
        #expect(QuestionExtractor.isGroupNumber("18～20"))
        #expect(QuestionExtractor.isGroupNumber("18-20"))
        #expect(!QuestionExtractor.isGroupNumber("18"))
    }

    @Test func flagsTextThatMentionsMissingFigures() throws {
        let result = try QuestionExtractor.extract(html: "<p>某物质的合成路线如下。回答问题。</p>", baseURL: base, anchor: "某物质的合成路线", lastAnchor: "").get()
        #expect(result.probablyMissingImages)
    }

    @Test func escapesMarkdownOnlyOutsideMath() {
        #expect(MarkdownRenderer.escape("a*b_c $x_1*y$ [1]") == "a\\*b\\_c $x_1*y$ \\[1\\]")
        #expect(QuestionExtractor.tidy("1. 题号\n# 标题\n- 列表") == "1\\. 题号\n\\# 标题\n\\- 列表")
    }
}

@Suite struct CompilationPlannerTests {
    @Test func ordersCandidatesAndDropsUnusableSites() {
        let ordered = CompilationPlanner.orderedCandidates([
            "https://zujuan.xkw.com/14q1.html",
            "http://zy.21cnjy.com/22743268",
            "https://zujuan.21cnjy.com/question?page=4",
            "https://zujuan.21cnjy.com/question/detail/63353387",
            "https://m.51jiaoxi.com/doc-1.html",
            "https://gaotu.cn/topic/8@1/483/400#1",
            "https://gaotu.cn/topic/8@1/483/400#1",
        ]).map(\.absoluteString)
        #expect(ordered == [
            "https://gaotu.cn/topic/8@1/483/400#1",
            "https://zujuan.21cnjy.com/question/detail/63353387",
            "https://zy.21cnjy.com/22743268",
            "https://zujuan.21cnjy.com/question?page=4",
        ])
        #expect(CompilationPlanner.siteName(for: URL(string: "https://www.gaotu.cn/x")!) == "高途")
        #expect(CompilationPlanner.siteName(for: URL(string: "https://zujuan.21cnjy.com/x")!) == "21 世纪教育网")
    }

    @Test func assemblesAssetsAndLabels() {
        let id = UUID()
        let markdown = "图一![](sa-image:0 \"w=10,h=5\")图二![](sa-image:1)"
        #expect(CompilationPlanner.assemble(markdown, assets: [0: id]) == "图一![](sa-asset:\(id.uuidString) \"w=10,h=5\")图二［图未能获取］")
        #expect(CompilationPlanner.label(year: "2025", paper: "北京卷", number: "17") == "2025 · 北京卷 · 第 17 题")
        #expect(CompilationPlanner.label(year: "", paper: "海淀一模", number: "") == "海淀一模")
    }

    @Test func estimatesCost() throws {
        let price = ModelPrice(input: 2, output: 8, currency: .cny, webSearchPer1000: 0, cachedInput: 0.04)
        // 每份：未命中 7.5 万 × 2 + 命中 22.5 万 × 0.04 + 输出 5 千 × 8，每百万 → 0.15 + 0.009 + 0.04 = 0.199
        let cost = try #require(CompilationPlanner.estimateCostCNY(papers: 3, price: price, usdToCNY: 7.2))
        #expect(abs(cost - 0.597) < 1e-9)
        #expect(CompilationPlanner.estimateCostCNY(papers: 3, price: nil, usdToCNY: 7.2) == nil)
    }
}
