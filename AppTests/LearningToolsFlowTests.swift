import Foundation
import PencilKit
import StudyKit
import SwiftData
import SwiftUI
import Testing
import XCTest
import WebKit
@testable import StudyAgent

@MainActor
private final class LearningToolsFixture {
    let container: ModelContainer
    let context: ModelContext
    let model: ChatModel
    let canvas: StudyCanvas
    let comparison: StudyInvestigation
    let conditions: StudyInvestigation
    let reading: StudyInvestigation
    let gaps: StudyInvestigation

    init() throws {
        container = try ModelContainer(for: Schema(StudyAgentSchema.models), configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        context = container.mainContext
        let provider = Provider(name: "测试", kind: .openAICompatible, baseURL: "https://example.invalid/v1")
        context.insert(provider)
        model = ChatModel(modelID: "test-model"); context.insert(model); model.provider = provider
        canvas = StudyCanvas(title: "二次函数专题"); context.insert(canvas)
        let graph = #"{"title":"y = ax²","xRange":[-3,3],"yRange":[-1,5],"params":[{"name":"a","min":1,"max":3,"step":1,"value":1}],"functions":[{"expr":"a*x^2","label":"y=ax²"}]}"#
        _ = try StudyCanvasStore.add(.init(title: "函数图像", content: "Canvas original\n```graph\n" + graph + "\n```"), to: canvas, at: MapPoint(x: 0, y: 0), context: context)
        comparison = StudyInvestigation(kind: .comparison, title: "方程的两种解法")
        try comparison.setMaterials([.init(title: "原题", content: "Solve x²-3x+2=0")])
        comparison.resultJSON = #"{"methods":[{"title":"因式分解","origin":"generated"},{"title":"求根公式","origin":"generated"}],"rows":[{"goal":"求根","cells":[{"text":"Factor: $(x-1)(x-2)=0$","conditions":["实数范围"],"keyIdea":"积为零","detour":"","originalQuote":""},{"text":"Formula: $x=\\frac{3\\pm1}{2}$","conditions":["二次项非零"],"keyIdea":"代入系数","detour":"","originalQuote":""}]}],"conclusion":"Both give x=1 or x=2."}"#
        conditions = StudyInvestigation(kind: .conditions, title: "条件改变后")
        let original = StudyMaterial(title: "原题", content: "Given x > 0, compare x² and 0.")
        let change = ConditionExploration.Change(operation: .replace, fragment: "x > 0", replacement: "x >= 0")
        try conditions.setMaterials([original, ConditionExploration.variant(original: original, change: change)])
        conditions.detailJSON = try StudyToolJSON.encode(change)
        conditions.resultJSON = #"{"steps":[{"originalStep":"Square is positive","sourceQuote":"","status":"changes","reason":"Zero is now allowed","revisedStep":"Square is nonnegative"}],"counterexample":{"status":"found","candidate":"x=0","verification":"Zero satisfies the new condition; x²=0."},"conclusion":"The strict inequality changes."}"#
        reading = StudyInvestigation(kind: .reading, title: "导数的定义")
        reading.inputText = "导数"
        let sources = [StudyMaterial(title: "教材", content: "Definition\nInstantaneous rate of change", location: "第 12 页"),
                       StudyMaterial(title: "讲义", content: "Instantaneous rate of change", location: "第一章")]
        try reading.setMaterials(sources)
        let evidence: [JSONValue] = sources.enumerated().map { index, source in
            ["sourceID": .string(source.id.uuidString), "startLine": .number(index == 0 ? 2 : 1), "endLine": .number(index == 0 ? 2 : 1), "quote": "Instantaneous rate of change"]
        }
        let rows: [JSONValue] = ["definition", "premise", "conclusion"].map { aspect in
            ["aspect": .string(aspect), "agreement": "agrees", "explanation": "Both sources describe the same rate.", "evidence": .array(evidence)]
        }
        reading.resultJSON = JSONValue.object(["comparisons": .array(rows), "synthesis": "Compare the existence of the limit."]).jsonString
        gaps = StudyInvestigation(kind: .gaps, title: "导数检查")
        let card = ConceptCard(title: "导数", content: "瞬时变化率"); context.insert(card)
        let prepared = try KnowledgeGapStore.prepare(target: card, context: context, hiddenIDs: [])
        try gaps.setMaterials(prepared.materials)
        let planJSON: JSONValue = ["questions": [["conceptID": .string(card.id.uuidString), "prompt": "What does a derivative measure?", "referenceAnswer": "Instantaneous rate of change", "rubric": "Mention the limit"]]]
        var session = prepared.session
        session.plan = try KnowledgeGap.parsePlan(planJSON.jsonString, conceptIDs: [card.id])
        session.answers[card.id.uuidString] = "平均变化率"
        gaps.detailJSON = try StudyToolJSON.encode(session)
        let findings: JSONValue = ["findings": [["conceptID": .string(card.id.uuidString), "verdict": "review", "evidenceQuote": "平均变化率", "reason": "The limiting process is missing.", "nextStep": "Review the limit definition."]]]
        gaps.resultJSON = findings.jsonString
        for record in [comparison, conditions, reading, gaps] {
            context.insert(record); record.modelID = model.id; record.modelName = "测试模型"; record.statusRaw = "complete"
        }
        try context.save()
    }
}

@MainActor @Suite struct LearningToolsFlowTests {
    @Test func savedInputsProduceValidatedResultsThroughTheSameWorkflowAsUI() async throws {
        let fixture = try LearningToolsFixture()
        for record in [fixture.comparison, fixture.conditions, fixture.reading] {
            let expected = record.resultJSON
            let prepared = try InvestigationWorkflow.prepare(record: record, model: fixture.model)
            record.resultJSON = ""
            let runner = InvestigationRunner()
            try await runner.run(record: record, request: prepared.request, model: fixture.model, context: fixture.context,
                                 service: InvestigationTestService(events: [.text(expected), .usage(input: 120, output: 40)]), validate: prepared.validate)
            #expect(record.statusRaw == "complete" && !record.resultJSON.isEmpty && record.inputTokens == 120)
        }
        let original = try fixture.conditions.materials()[0]
        var changed = try fixture.conditions.materials(); changed[1].content = "tampered variant"
        try fixture.conditions.setMaterials(changed)
        #expect(throws: StudyToolError.self) { try InvestigationWorkflow.prepare(record: fixture.conditions, model: fixture.model) }
        #expect(try fixture.conditions.materials()[0] == original)
        #expect(throws: StudyToolError.self) { try InvestigationWorkflow.prepare(record: fixture.gaps, model: fixture.model) }
    }

    @Test func canvasQuestionStartsLinkedConversationAndDoesNotSendUnselectedMaterial() async throws {
        let fixture = try LearningToolsFixture()
        let a = try #require(fixture.canvas.sortedItems.first)
        _ = try StudyCanvasStore.add(.init(title: "未选", content: "DO_NOT_SEND"), to: fixture.canvas, at: MapPoint(x: 900, y: 0), context: fixture.context)
        let generation = GenerationCenter(service: InvestigationTestService(events: [.text("根据选中图像解释。")]))
        let conversation = try StudyCanvasStore.ask("解释曲线", selected: [a.id], canvas: fixture.canvas, model: fixture.model,
                                                    context: fixture.context, generation: generation)
        for _ in 0..<200 {
            if !generation.isGenerating(conversation) { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(conversation.sourceCanvasID == fixture.canvas.id)
        #expect(conversation.sortedMessages.first?.content.contains("DO_NOT_SEND") == false)
        #expect(conversation.sortedMessages.last?.status == .complete)
        fixture.context.delete(fixture.canvas); try fixture.context.save()
        #expect(try fixture.context.fetchCount(FetchDescriptor<Conversation>()) == 1)
        #expect(conversation.sortedMessages.first?.content.contains("Canvas original") == true)
    }

    @Test func handwritingReopensAsEditableDrawing() throws {
        let fixture = try LearningToolsFixture()
        let item = try #require(fixture.canvas.sortedItems.first)
        let controller = HandwritingCanvasController()
        #expect(controller.exportJPEG() == nil)
        let points = [CGPoint(x: 20, y: 30), CGPoint(x: 100, y: 120)].enumerated().map { index, point in
            PKStrokePoint(location: point, timeOffset: Double(index) * 0.1, size: CGSize(width: 4, height: 4), opacity: 1, force: 1, azimuth: 0, altitude: .pi / 2)
        }
        controller.canvasView.drawing = PKDrawing(strokes: [PKStroke(ink: PKInk(.pen, color: .black), path: PKStrokePath(controlPoints: points, creationDate: .now))])
        #expect(controller.exportJPEG()?.starts(with: [0xff, 0xd8]) == true)
        item.drawingData = controller.canvasView.drawing.dataRepresentation()
        try fixture.context.save()
        let stored = try #require(ModelContext(fixture.container).fetch(FetchDescriptor<CanvasItem>()).first)
        #expect(stored.drawingData == item.drawingData)
        let drawing = try PKDrawing(data: #require(stored.drawingData))
        #expect(drawing.strokes.count == 1)
        controller.clear()
        #expect(controller.exportJPEG() == nil)
    }
}

@MainActor final class LearningToolsPresentationTests: XCTestCase {
    func testScreensRenderOriginalsResultsAndEvidence() async throws {
        let fixture = try LearningToolsFixture()
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let previous = scene.windows.first { $0.isKeyWindow }
        let window = UIWindow(windowScene: scene); window.windowLevel = .normal + 1
        defer { window.isHidden = true; window.rootViewController = nil; previous?.makeKeyAndVisible() }

        func webViews(_ view: UIView) -> [WKWebView] {
            (view as? WKWebView).map { [$0] } ?? view.subviews.flatMap(webViews)
        }
        func show<V: View>(_ view: V, name: String, expected: String? = nil, dark: Bool = false) async throws {
            let root = view.modelContainer(fixture.container).environment(AppNavigation()).environment(GenerationCenter())
                .environment(CompilationCenter()).environment(ToastCenter())
            let host = UIHostingController(rootView: root)
            host.overrideUserInterfaceStyle = dark ? .dark : .light
            window.rootViewController = host; window.makeKeyAndVisible(); host.view.layoutIfNeeded()
            try await Task.sleep(for: .milliseconds(500))
            if let expected {
                let deadline = Date().addingTimeInterval(35)
                var rendered = false
                while Date() < deadline && !rendered {
                    for web in webViews(host.view) {
                        if let text = try? await web.evaluateJavaScript("document.body.innerText") as? String, text.contains(expected) { rendered = true }
                    }
                    if !rendered { try await Task.sleep(for: .milliseconds(100)) }
                }
                XCTAssertTrue(rendered, "Expected rendered content: \(expected)")
            }
            if name.hasPrefix("学习画布") {
                let web = try XCTUnwrap(webViews(host.view).first)
                let deadline = Date().addingTimeInterval(20)
                var ready = false
                while !ready && Date() < deadline {
                    ready = (try? await web.evaluateJavaScript("!!document.querySelector('.graph-board svg') && !!document.querySelector('.graph-controls input')") as? Bool) == true
                    if !ready { try await Task.sleep(for: .milliseconds(100)) }
                }
                XCTAssertTrue(ready, "应实际画出曲线并创建参数滑块")
                if ready && name == "学习画布" {
                    _ = try await web.evaluateJavaScript("var slider=document.querySelector('.graph-controls input'); slider.value='2'; slider.dispatchEvent(new Event('input',{bubbles:true})); slider.dispatchEvent(new Event('change',{bubbles:true}));")
                    let item = try XCTUnwrap(fixture.canvas.sortedItems.first)
                    for _ in 0..<100 {
                        if item.componentStateJSON.contains("2") { break }
                        try await Task.sleep(for: .milliseconds(20))
                    }
                    XCTAssertEqual((ComponentStateStore.decode(item.componentStateJSON)["c0"] as? [String: Any])?["a"] as? Int, 2)
                    let saved = try XCTUnwrap(ModelContext(fixture.container).fetch(FetchDescriptor<CanvasItem>()).first)
                    XCTAssertEqual(saved.componentStateJSON, item.componentStateJSON)
                } else if ready {
                    let value = try await web.evaluateJavaScript("document.querySelector('.graph-controls input').value") as? String
                    XCTAssertEqual(value, "2", "重新打开画布应恢复参数")
                }
            }
            XCTAssertGreaterThan(host.view.bounds.width, 300)
            let image = UIGraphicsImageRenderer(bounds: host.view.bounds).image { _ in
                host.view.drawHierarchy(in: host.view.bounds, afterScreenUpdates: true)
            }
            let attachment = XCTAttachment(image: image); attachment.name = name; attachment.lifetime = .keepAlways; add(attachment)
            // 分别保存页面和 WebView，避免把异步快照叠加后产生重影或错误缩放。
            for (index, web) in webViews(host.view).enumerated() where web.bounds.width > 0 && web.bounds.height > 0 && web.bounds.height < 10_000 {
                if let image = try? await web.takeSnapshot(configuration: nil) {
                    let attachment = XCTAttachment(image: image)
                    attachment.name = "\(name)正文 \(index + 1)"; attachment.lifetime = .keepAlways; add(attachment)
                }
            }
        }
        try await show(NavigationStack { StudyCanvasView(canvas: fixture.canvas) }, name: "学习画布", expected: "Canvas original")
        try await show(NavigationStack { InvestigationsView() }, name: "学习探索入口")
        try await show(NavigationStack { StudyCanvasView(canvas: fixture.canvas) }, name: "学习画布恢复", expected: "Canvas original")
        try await show(NavigationStack { InvestigationDetailView(record: fixture.comparison) }, name: "多解对照", expected: "Factor:")
        try await show(NavigationStack { KnowledgeGapDetailView(record: fixture.gaps) }, name: "知识缺口作答与建议", expected: "What does a derivative", dark: true)
        try await show(NavigationStack { InvestigationDetailView(record: fixture.conditions) }, name: "条件探索", expected: "Square is positive")
        try await show(NavigationStack { InvestigationDetailView(record: fixture.reading) }, name: "资料对照阅读", expected: "Both sources")
        let materials = try fixture.reading.materials()
        let result = try ReadingComparison.parse(fixture.reading.resultJSON, materials: materials)
        try await show(StudyMaterialSheet(material: materials[0], evidence: result.comparisons[0].evidence[0]), name: "原文定位")
        let card = try ReadingComparisonStore.saveCard(record: fixture.reading, title: "导数", content: "Confirmed understanding", subject: .math, context: fixture.context)
        try await show(ReadingCardEvidenceSheet(card: card), name: "知识卡保留原文", expected: "Both sources")
    }
}
