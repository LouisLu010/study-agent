import Foundation
import StudyKit
import SwiftData

enum AppSettingsKey {
    /// 默认模型的 `ChatModel.id`。
    static let defaultModelID = "defaultModelID"
    /// 用户提示词。
    static let customInstructions = "customInstructions"
    /// 简洁模式：不让模型使用组件。
    static let simpleMode = "simpleMode"
    /// 美元兑人民币的汇率，用来把美元价格折算成人民币。
    static let usdToCNY = "usdToCNY"
    static let defaultUSDToCNY = 7.2
    /// 强力保活：生成汇编期间开后台定位，让 App 在后台持续运行（见 docs/adr/0012）。
    static let strongKeepAlive = "strongKeepAlive"
    /// 用户已经看完或跳过了引导。本机没有服务商、这一项也没有时，打开 App 会显示引导。
    static let onboardingSeen = "onboardingSeen"

    static var usdToCNYRate: Double {
        let value = UserDefaults.standard.double(forKey: usdToCNY)
        return value > 0 ? value : defaultUSDToCNY
    }
}

@MainActor
enum ModelLookup {
    /// 这个模型对应的聊天服务。
    static func service(for model: ChatModel) throws -> any ChatService {
        guard let provider = model.provider else { throw GenerationError.noModel }
        return try ChatServiceFactory.makeService(
            kind: provider.kind,
            baseURL: provider.baseURL,
            apiKey: KeychainStore.apiKey(for: provider.id) ?? ""
        )
    }

    /// 默认模型；没有设置时返回最早添加的模型。
    static func defaultModel(in context: ModelContext) -> ChatModel? {
        let descriptor = FetchDescriptor<ChatModel>(sortBy: [SortDescriptor(\.createdAt)])
        let models = (try? context.fetch(descriptor)) ?? []
        let defaultID = UserDefaults.standard.string(forKey: AppSettingsKey.defaultModelID)
        return models.first { $0.id.uuidString == defaultID } ?? models.first
    }
}
