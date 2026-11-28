import Foundation
import Testing
@testable import StudyKit

@Suite struct CompilationBatchTests {
    private let paper = PaperPlan(title: "2025 年普通高等学校招生全国统一考试（北京卷）化学", shortTitle: "北京卷", year: "2025")

    @Test func batchRequestsUseOneNativeSearchAndNoFunctionTools() throws {
        let list = CompilationBatch.listingRequest(model: "deepseek-flash", request: "近 3 年有机大题", dialect: .deepSeek)
        let discovery = CompilationBatch.discoveryRequest(model: "deepseek-flash", request: "有机大题", paper: paper, dialect: .deepSeek)
        let service = OpenAICompatibleService(baseURL: URL(string: "https://api.deepseek.com")!, apiKey: "test")
        for request in [list, discovery] {
            #expect(request.webSearch)
            #expect(request.webSearchDialect == .deepSeek)
            #expect(request.tools.isEmpty)
            #expect(request.reasoningEffort == .low)
            let body = try #require(service.makeURLRequest(for: request).httpBody)
            let json = try #require(JSONSerialization.jsonObject(with: body) as? [String: Any])
            #expect(json["tools"] as? [[String: String]] == [["type": "deepseek_web_search"]])
        }
        #expect(discovery.messages.first?.text.contains(paper.title) == true)
    }

    @Test func selectionUsesOnlyDownloadedDocumentsAndExistingQuestions() {
        let request = CompilationBatch.selectionRequest(
            model: "m", request: "有机大题", paper: paper,
            documents: "S1 B1：题干", existing: "Q1：第 17 题"
        )
        #expect(!request.webSearch)
        #expect(request.tools.isEmpty)
        #expect(request.reasoningEffort == .low)
        #expect(request.messages.first?.text.contains("S1 B1：题干") == true)
        #expect(request.messages.first?.text.contains("Q1：第 17 题") == true)
        #expect(request.messages.first?.text.contains(paper.title) == true)
    }

    @Test func decodesOldPaperPlansWithoutClaimingCompleteness() throws {
        let id = UUID()
        let json = """
        {"id":"\(id.uuidString)","title":"北京卷","shortTitle":"北京卷","year":"2025","selected":true,"state":"done","found":1,"note":""}
        """
        let old = try JSONDecoder().decode(PaperPlan.self, from: Data(json.utf8))
        #expect(old.id == id)
        #expect(old.state == .done)
        #expect(old.sourceURLs.isEmpty)
        #expect(!old.collectionComplete)
    }

    @Test func preservesNewPaperPlanFieldsWhenSaving() throws {
        var value = paper
        value.sourceURLs = ["https://example.org/paper"]
        value.collectionComplete = true
        let saved = try JSONEncoder().encode(value)
        #expect(try JSONDecoder().decode(PaperPlan.self, from: saved) == value)
        #expect(!paper.collectionComplete)
        #expect(paper.sourceURLs.isEmpty)
    }

    @Test func parsesListingAndCarriesItsSourcesForward() throws {
        let json = #"{"title":"有机大题","subject":"化学","papers":[{"title":"2025 北京卷化学","short":"北京卷","year":"2025","sources":["http://example.org/paper#q17","https://example.org/paper","javascript:alert(1)"]}]}"#
        let result = try CompilationBatch.parseListing("```json\n" + json + "\n```", fallbackTitle: "备用标题").get()
        #expect(result.title == "有机大题")
        #expect(result.subject == .chemistry)
        #expect(result.papers.count == 1)
        #expect(result.papers.first?.sourceURLs == ["https://example.org/paper"])
        #expect(result.papers.first?.collectionComplete == false)
        let old = try CompilationBatch.parseListing(#"{"papers":[{"title":"北京卷","year":"2025"}]}"#, fallbackTitle: "备用标题").get()
        #expect(old.title == "备用标题")
        #expect(old.papers.first?.sourceURLs.isEmpty == true)
    }

    @Test func rejectsMalformedListingsAndWrongSourceTypes() {
        for raw in ["没有试卷", "{}", #"{"papers":[]}"#, #"{"papers":[{"title":"北京卷","year":"25"}]}"#, #"{"papers":[{"title":"北京卷","year":"2025","sources":"https://example.org"}]}"#] {
            #expect(throws: CompilationTools.ArgumentError.self) {
                try CompilationBatch.parseListing(raw, fallbackTitle: "备用").get()
            }
        }
    }

    @Test func sourcesOnlyContainSafeWebURLsAndHaveALimit() throws {
        let values = [
            "https://example.org/paper#first", "http://example.org/paper#second",
            "javascript:alert(1)", "file:///etc/passwd", "https://user:password@example.org/paper",
            "https://localhost/paper", "https://127.0.0.1/paper", "https://10.0.0.2/paper",
            "https://[::1]/paper", "https://device.local/paper", "https://example.org:8080/paper",
            "https://example.org/bad path", "not-a-url",
        ] + (1...9).map { "https://example.org/paper\($0)" }
        let safe = CompilationBatch.validSourceURLs(values)
        #expect(safe.count == 6)
        #expect(safe.first == "https://example.org/paper")
        #expect(Set(safe).count == safe.count)
        let json = JSONValue.object(["sources": .array(values.map(JSONValue.string))]).jsonString
        #expect(try CompilationBatch.parseSources(json).get() == safe)
        #expect(try CompilationBatch.parseSources(#"{"sources":[]}"#).get().isEmpty)
    }

    @Test func rejectsMalformedSourceResponses() {
        for raw in ["{}", "[]", #"{"sources":null}"#, #"{"sources":[1]}"#, #"说明：{"sources":[]}"#, #"{"sources":["https://example.org"]"#] {
            #expect(throws: CompilationTools.ArgumentError.self) { try CompilationBatch.parseSources(raw).get() }
        }
    }

    @Test func parsesRangesLinksAndReuseWithoutInventingSources() throws {
        let raw = #"{"matches_paper":true,"questions":[{"number":"第 18-20 题","source_id":"S1","start_id":"B3","end_id":"B9","group":true}],"links":[{"source_id":"S1","link_id":"L2"}],"reuse":["Q1","Q1"],"complete":false,"note":"目录还要打开一页"}"#
        let selection = try CompilationBatch.parseSelection(raw).get()
        #expect(selection.matchesPaper)
        #expect(selection.questions == [.init(number: "18～20", sourceID: "S1", startID: "B3", endID: "B9", group: true)])
        #expect(selection.links == [.init(sourceID: "S1", linkID: "L2")])
        #expect(selection.reuse == ["Q1"])
        #expect(!selection.complete)
        #expect(selection.note == "目录还要打开一页")
    }

    @Test func distinguishesNoMatchingQuestionsFromAnUnverifiedPaper() throws {
        let empty = try CompilationBatch.parseSelection(#"{"matches_paper":true,"questions":[],"links":[],"reuse":[],"complete":true,"note":"已检查整卷，没有有机大题"}"#).get()
        #expect(empty.complete)
        #expect(empty.questions.isEmpty)
        let unknown = try CompilationBatch.parseSelection(#"{"matches_paper":false,"questions":[],"links":[],"reuse":[],"complete":false,"note":"页面没有年份"}"#).get()
        #expect(!unknown.complete)
        #expect(!unknown.matchesPaper)
    }

    @Test func aVerifiedDirectoryCanSelectAllItsLinksBeforeFetching() throws {
        let selection = try CompilationBatch.parseSelection(#"{"matches_paper":true,"questions":[],"links":[{"source_id":"S1","link_id":"L1"}],"reuse":[],"complete":true,"note":"完整目录中只有这一道有机大题，App 还需打开详情"}"#).get()
        #expect(selection.complete)
        #expect(selection.links == [.init(sourceID: "S1", linkID: "L1")])
    }

    @Test func parserErrorsProvideTheirMessageToTheApp() {
        let error = CompilationTools.ArgumentError("试卷年份不一致")
        #expect(error.localizedDescription == "试卷年份不一致")
    }

    @Test func rejectsBrokenOrContradictorySelections() {
        let valid: JSONValue = ["matches_paper": true, "questions": [], "links": [], "reuse": [], "complete": true, "note": "没有符合要求的题"]
        var cases = ["{}", "[]", "说明：" + valid.jsonString, String(valid.jsonString.dropLast())]
        let missingFields = ["matches_paper", "questions", "links", "reuse", "complete", "note"].map { key -> String in
            var fields = valid.objectValue!
            fields.removeValue(forKey: key)
            return JSONValue.object(fields).jsonString
        }
        cases += missingFields
        cases += [
            #"{"matches_paper":false,"questions":[],"links":[],"reuse":[],"complete":true,"note":"未核实"}"#,
            #"{"matches_paper":true,"questions":[{"number":"17","source_id":"S1","start_id":"B1","group":false}],"links":[],"reuse":[],"complete":false,"note":"缺 end_id"}"#,
            #"{"matches_paper":true,"questions":[],"links":[{"url":"https://example.org"}],"reuse":[],"complete":false,"note":"生成了网址"}"#,
            #"{"matches_paper":true,"questions":[],"links":[],"reuse":[""],"complete":false,"note":"空 ID"}"#,
            #"{"matches_paper":"true","questions":[],"links":[],"reuse":[],"complete":true,"note":"布尔值不能是字符串"}"#,
        ]
        for raw in cases {
            #expect(throws: CompilationTools.ArgumentError.self) { try CompilationBatch.parseSelection(raw).get() }
        }
    }
}
