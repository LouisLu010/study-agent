import Foundation
import StudyKit
import SwiftData
import Testing
@testable import StudyAgent

struct InvestigationTestService: ChatService {
    let events: [ChatStreamEvent]
    var failure: ChatServiceError?
    var hold = false
    func streamChat(_ request: ChatRequest) -> AsyncThrowingStream<ChatStreamEvent, any Error> {
        AsyncThrowingStream { continuation in
            for event in events { continuation.yield(event) }
            if let failure { continuation.finish(throwing: failure) }
            else if !hold { continuation.finish() }
        }
    }
}

@MainActor @Suite struct InvestigationRunnerTests {
    private func fixture() throws -> (ModelContainer, ModelContext, StudyInvestigation, ChatModel) {
        let container = try ModelContainer(for: Schema(StudyAgentSchema.models), configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        let context = ModelContext(container)
        let record = StudyInvestigation(kind: .comparison, title: "测试")
        try record.setMaterials([.init(title: "题", content: "原题")])
        context.insert(record)
        let model = ChatModel(modelID: "test"); model.customInputPrice = 2; model.customOutputPrice = 4
        context.insert(model); try context.save()
        return (container, context, record, model)
    }

    @Test func savesValidatedResultUsageAndOriginalMaterials() async throws {
        let (container, context, record, model) = try fixture()
        let service = InvestigationTestService(events: [.text("{\"ok\":true}"), .usage(input: 100, output: nil), .usage(input: nil, output: 20), .cachedInput(5)])
        let runner = InvestigationRunner()
        try await runner.run(record: record, request: .init(model: "test", messages: []), model: model, context: context, service: service) { raw in
            #expect(JSONValue.parse(raw)?["ok"] == .bool(true)); return raw
        }
        let stored = try #require(ModelContext(container).fetch(FetchDescriptor<StudyInvestigation>()).first)
        #expect(stored.statusRaw == "complete" && stored.inputTokens == 100 && stored.outputTokens == 20)
        #expect(stored.costCNY == 0.00028 && stored.modelID == model.id)
        #expect(try stored.materials().first?.content == "原题")
        #expect(!runner.isRunning)
    }

    @Test func invalidOutputAndNetworkFailurePreservePreviousResult() async throws {
        let (_, context, record, model) = try fixture()
        record.resultJSON = "original"
        let runner = InvestigationRunner()
        await #expect(throws: StudyToolError.self) {
            try await runner.run(record: record, request: .init(model: "test", messages: []), model: model, context: context,
                                 service: InvestigationTestService(events: [.text("invalid"), .usage(input: 1, output: 1)])) { _ in
                throw StudyToolError.invalidOutput("测试")
            }
        }
        #expect(record.resultJSON == "original" && record.statusRaw == "failed" && record.inputTokens == 1)
        await #expect(throws: (any Error).self) {
            try await runner.run(record: record, request: .init(model: "test", messages: []), model: model, context: context,
                                 service: InvestigationTestService(events: [], failure: .emptyResponse)) { $0 }
        }
        #expect(record.resultJSON == "original" && !runner.isRunning)
    }

    @Test func boundsOutputCancelsAndRecoversInterruptedRuns() async throws {
        let (_, context, record, model) = try fixture()
        let runner = InvestigationRunner()
        await #expect(throws: StudyToolError.tooLong) {
            try await runner.run(record: record, request: .init(model: "test", messages: []), model: model, context: context,
                                 service: InvestigationTestService(events: [.reasoning(String(repeating: "字", count: 64_001))])) { $0 }
        }
        let task = Task { try await runner.run(record: record, request: .init(model: "test", messages: []), model: model, context: context,
                                               service: InvestigationTestService(events: [], hold: true)) { $0 } }
        for _ in 0..<100 {
            if runner.isRunning { break }
            try await Task.sleep(for: .milliseconds(5))
        }
        task.cancel()
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(record.statusRaw == "stopped" && record.resultJSON.isEmpty)
        record.statusRaw = "generating"
        try InvestigationRunner.recover(record, context: context)
        #expect(record.statusRaw == "stopped" && record.errorText?.contains("中断") == true)
    }

    @Test func imageInputsRequireCompatibleModelAndLimitCount() throws {
        let (_, _, _, model) = try fixture()
        let material = StudyMaterial(title: "图片", content: "题", images: [.init(data: Data([1]))])
        let request = ChatRequest(model: "test", messages: [.init(role: .user, text: "题")])
        #expect(throws: GenerationError.self) { try InvestigationRunner.attachImages([material], to: request, model: model) }
        model.supportsImages = true
        #expect(throws: StudyMaterialStore.MaterialError.self) { try InvestigationRunner.attachImages([material], to: request, model: model) }
        #expect(throws: StudyMaterialStore.MaterialError.self) { try InvestigationRunner.attachImages(Array(repeating: material, count: 13), to: request, model: model) }
    }
}
