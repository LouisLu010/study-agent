import StudyKit

/// 从已保存的材料建立请求和校验闭包，生成过程始终使用同一份输入快照。
@MainActor
enum InvestigationWorkflow {
    struct Prepared {
        let request: ChatRequest
        let validate: (String) throws -> String
    }

    static func prepare(record: StudyInvestigation, model: ChatModel) throws -> Prepared {
        let materials = try record.materials(), input = record.inputText
        guard let question = materials.first else { throw StudyToolError.invalidInput("没有可读取的原材料。") }
        let request: ChatRequest
        let validate: (String) throws -> String
        switch record.kind {
        case .reading:
            request = try ReadingComparison.request(model: model.modelID, concept: input, materials: materials, reasoning: model.reasoningEffort)
            validate = { try StudyToolJSON.encode(ReadingComparison.parse($0, materials: materials)) }
        case .conditions:
            let change = try StudyToolJSON.decode(ConditionExploration.Change.self, from: record.detailJSON)
            guard materials.count == 2, try ConditionExploration.variant(original: question, change: change).content == materials[1].content else {
                throw StudyToolError.invalidInput("变式与保存的条件变化不一致，请重新创建探索。")
            }
            request = try ConditionExploration.request(model: model.modelID, original: question, change: change, solution: input, reasoning: model.reasoningEffort)
            validate = { try StudyToolJSON.encode(ConditionExploration.parse($0, solution: input)) }
        case .comparison:
            request = try SolutionComparison.request(model: model.modelID, question: question, ownSolution: input, reasoning: model.reasoningEffort)
            validate = { try StudyToolJSON.encode(SolutionComparison.parse($0, ownSolution: input)) }
        default: throw StudyToolError.invalidInput("请从相应的探索页面继续。")
        }
        let prepared = record.kind == .reading ? request : try InvestigationRunner.attachImages([question], to: request, model: model)
        return Prepared(request: prepared, validate: validate)
    }
}
