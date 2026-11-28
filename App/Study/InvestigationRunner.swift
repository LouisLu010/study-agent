import Foundation
import Observation
import StudyKit
import SwiftData

/// 单次结构化分析。离开页面时取消，输入先保存，完整结果通过校验后再替换。
@MainActor @Observable
final class InvestigationRunner {
    private(set) var isRunning = false
    private(set) var characterCount = 0
    private static var activeIDs: Set<UUID> = []

    static func recover(_ record: StudyInvestigation, context: ModelContext) throws {
        if record.statusRaw == "generating", !activeIDs.contains(record.id) {
            record.statusRaw = "stopped"
            record.errorText = "上次分析被中断，可以重新生成。"
            try context.save()
        }
    }

    func run(record: StudyInvestigation, request: ChatRequest, model: ChatModel, context: ModelContext,
             service: any ChatService, savesDetail: Bool = false, validate: (String) throws -> String) async throws {
        guard !Self.activeIDs.contains(record.id) else { throw StudyToolError.invalidInput("这份内容正在分析。") }
        guard !record.isDeleted, record.modelContext != nil else { throw CancellationError() }
        Self.activeIDs.insert(record.id)
        isRunning = true; characterCount = 0
        record.statusRaw = "generating"; record.errorText = nil
        record.modelID = model.id; record.modelName = model.name
        let started = Date(), price = model.price()
        var input = 0, output = 0, cached = 0
        var raw = ""
        defer { isRunning = false; Self.activeIDs.remove(record.id) }
        func account() {
            record.inputTokens += input; record.outputTokens += output
            if let price, input > 0 || output > 0 {
                record.costCNY = (record.costCNY ?? 0) + price.costCNY(inputTokens: input, cachedInputTokens: cached, outputTokens: output,
                                                                  usdToCNY: AppSettingsKey.usdToCNYRate, at: started)
            }
            record.updatedAt = .now
        }
        var accounted = false
        do {
            try context.save()
            for try await event in service.streamChat(request) {
                try Task.checkCancellation()
                guard !record.isDeleted, record.modelContext != nil else { throw CancellationError() }
                switch event {
                case let .text(delta): raw += delta; characterCount += delta.count
                case let .reasoning(delta): characterCount += delta.count
                case let .usage(i, o): input = max(0, i ?? input); output = max(0, o ?? output)
                case let .cachedInput(value): cached = max(0, value)
                default: break
                }
                guard characterCount <= 64_000, raw.utf8.count <= 256_000 else { throw StudyToolError.tooLong }
            }
            try Task.checkCancellation()
            let result = try validate(raw)
            account(); accounted = true
            if savesDetail { record.detailJSON = result } else { record.resultJSON = result }
            record.statusRaw = "complete"
            try context.save()
        } catch {
            if !record.isDeleted, record.modelContext != nil {
                if !accounted { account() }
                record.statusRaw = Task.isCancelled || error is CancellationError ? "stopped" : "failed"
                record.errorText = record.statusRaw == "stopped" ? "已停止，可以重新生成。" : ChatErrorDescription.describe(error)
                try? context.save()
            }
            throw error
        }
    }

    static func attachImages(_ materials: [StudyMaterial], to request: ChatRequest, model: ChatModel) throws -> ChatRequest {
        let images = materials.flatMap(\.images)
        guard images.count <= 12 else { throw StudyMaterialStore.MaterialError.tooManyImages }
        guard images.isEmpty || model.supportsImages else { throw GenerationError.modelDoesNotSupportImages }
        var request = request
        guard !request.messages.isEmpty else { throw StudyToolError.invalidInput("缺少分析材料。") }
        request.messages[0].images = try StudyMaterialStore.jpegImages(images)
        return request
    }
}
