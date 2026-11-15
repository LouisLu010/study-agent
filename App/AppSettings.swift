import Foundation
import StudyKit
import SwiftData

enum AppSettingsKey {
    /// 默认模型的 `ChatModel.id`。
    static let defaultModelID = "defaultModelID"
    /// 用户提示词。
    static let customInstructions = "customInstructions"
}

@MainActor
enum ModelLookup {
    /// 默认模型；没有设置时返回最早添加的模型。
    static func defaultModel(in context: ModelContext) -> ChatModel? {
        let descriptor = FetchDescriptor<ChatModel>(sortBy: [SortDescriptor(\.createdAt)])
        let models = (try? context.fetch(descriptor)) ?? []
        let defaultID = UserDefaults.standard.string(forKey: AppSettingsKey.defaultModelID)
        return models.first { $0.id.uuidString == defaultID } ?? models.first
    }
}
