import Foundation

/// 服务商预设：App 内置的一家常用服务商的模板（见 GLOSSARY「服务商预设」）。
/// 用预设建出来的仍是普通的服务商，之后可以随意修改。地址按各家官方文档填写。
public struct ProviderPreset: Identifiable, Hashable, Sendable {
    public let id: String
    public let name: String
    public let kind: ProviderKind
    /// 为空表示要用户自己填（"其他"）。
    public let baseURL: String
    /// 拉下来的模型是否默认打开"支持联网搜索"。只有这家所有模型都能用自带搜索时才打开。
    public let webSearchByDefault: Bool
    /// 推荐的默认模型。在模型列表里时排第一并默认选中。
    public let recommendedModelID: String?
    /// 获取 API Key 的网页。
    public let apiKeyPage: String?

    /// "其他（OpenAI 兼容）"：地址由用户填写。
    public var isCustom: Bool { id == Self.customID }

    static let customID = "custom"

    public static let all: [ProviderPreset] = [
        ProviderPreset(
            id: "deepseek", name: "DeepSeek", kind: .openAICompatible,
            baseURL: "https://api.deepseek.com",
            webSearchByDefault: true, recommendedModelID: "deepseek-flash",
            apiKeyPage: "https://platform.deepseek.com/api_keys"
        ),
        ProviderPreset(
            id: "openai", name: "OpenAI", kind: .openAICompatible,
            baseURL: "https://api.openai.com/v1",
            webSearchByDefault: false, recommendedModelID: nil,
            apiKeyPage: "https://platform.openai.com/api-keys"
        ),
        ProviderPreset(
            id: "anthropic", name: "Anthropic", kind: .anthropic,
            baseURL: "https://api.anthropic.com/v1",
            webSearchByDefault: true, recommendedModelID: nil,
            apiKeyPage: "https://console.anthropic.com/settings/keys"
        ),
        ProviderPreset(
            id: "gemini", name: "Google Gemini", kind: .gemini,
            baseURL: "https://generativelanguage.googleapis.com/v1beta",
            webSearchByDefault: true, recommendedModelID: nil,
            apiKeyPage: "https://aistudio.google.com/apikey"
        ),
        ProviderPreset(
            id: "openrouter", name: "OpenRouter", kind: .openAICompatible,
            baseURL: "https://openrouter.ai/api/v1",
            webSearchByDefault: false, recommendedModelID: nil,
            apiKeyPage: "https://openrouter.ai/settings/keys"
        ),
        ProviderPreset(
            id: customID, name: "其他（OpenAI 兼容）", kind: .openAICompatible,
            baseURL: "",
            webSearchByDefault: false, recommendedModelID: nil,
            apiKeyPage: nil
        ),
    ]

    /// 按协议和地址的域名找回对应的预设，用来给手动建的或旧版本建的服务商套用预设的默认值。
    public static func matching(kind: ProviderKind, baseURL: String) -> ProviderPreset? {
        guard let host = Self.host(of: baseURL) else { return nil }
        return all.first { !$0.isCustom && $0.kind == kind && Self.host(of: $0.baseURL) == host }
    }

    /// 推荐模型排第一，其余保持服务商返回的顺序。
    public func ordered(_ models: [RemoteModel]) -> [RemoteModel] {
        guard let recommended = recommendedModelID,
              let index = models.firstIndex(where: { $0.id == recommended })
        else { return models }
        var result = models
        result.insert(result.remove(at: index), at: 0)
        return result
    }

    private static func host(of address: String) -> String? {
        URL(string: address.trimmingCharacters(in: .whitespacesAndNewlines))?.host()?.lowercased()
    }
}
