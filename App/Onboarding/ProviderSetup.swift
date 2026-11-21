import Foundation
import StudyKit
import SwiftData

/// 用服务商预设建服务商和模型。引导和设置里的"添加服务商"共用。
@MainActor
enum ProviderSetup {
    /// 按预设新建一个服务商并插入。"其他"用 OpenAI 兼容协议的默认地址，名称是"新服务商"。
    static func makeProvider(from preset: ProviderPreset, name: String? = nil, baseURL: String? = nil, in context: ModelContext) -> Provider {
        let address = baseURL ?? (preset.isCustom ? preset.kind.defaultBaseURL : preset.baseURL)
        let provider = Provider(
            name: name ?? (preset.isCustom ? "新服务商" : preset.name),
            kind: preset.kind,
            baseURL: address.trimmingCharacters(in: .whitespacesAndNewlines)
        )
        context.insert(provider)
        return provider
    }

    /// 把服务商列表里的一个模型加到这个服务商下。是否支持联网搜索按预设的默认值；
    /// 还没有默认模型时，它就是默认模型。
    @discardableResult
    static func addModel(_ remote: RemoteModel, to provider: Provider, in context: ModelContext) -> ChatModel {
        let displayName = remote.displayName == remote.id ? "" : remote.displayName
        let model = ChatModel(modelID: remote.id, displayName: displayName, supportsImages: remote.supportsImages ?? false)
        model.supportsWebSearch = ProviderPreset.matching(kind: provider.kind, baseURL: provider.baseURL)?.webSearchByDefault ?? false
        context.insert(model)
        model.provider = provider
        let defaults = UserDefaults.standard
        if (defaults.string(forKey: AppSettingsKey.defaultModelID) ?? "").isEmpty {
            defaults.set(model.id.uuidString, forKey: AppSettingsKey.defaultModelID)
        }
        return model
    }

    /// 验证 API Key 失败时给用户看的说明：分成 Key 不对、地址不对、网络不通。
    static func describeKeyCheckError(_ error: any Error) -> String {
        if let error = error as? ChatServiceError {
            switch error {
            case .missingAPIKey:
                return "请先填写 API Key。"
            case .invalidBaseURL:
                return "地址不对：API 地址需要以 https:// 开头。"
            case let .http(status, _) where status == 401 || status == 403:
                return "API Key 不对：服务商拒绝了这个 Key（HTTP \(status)）。请检查有没有复制完整，或者 Key 是否已经停用。"
            case let .http(status, _) where status == 404:
                return "地址不对：服务商没有这个接口（HTTP 404）。请检查 API 地址。"
            default:
                return error.localizedDescription
            }
        }
        if let error = error as? URLError {
            switch error.code {
            case .cannotFindHost, .dnsLookupFailed, .unsupportedURL, .badURL:
                return "地址不对：找不到这个服务器，请检查 API 地址。"
            case .notConnectedToInternet, .networkConnectionLost, .dataNotAllowed, .timedOut, .cannotConnectToHost:
                return "网络不通：连不上服务商。请检查网络，或者稍后再试。"
            default:
                break
            }
        }
        return ChatErrorDescription.describe(error)
    }
}
