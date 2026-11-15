import Foundation

/// 服务商使用的 API 协议。
public enum ProviderKind: String, CaseIterable, Identifiable, Sendable {
    case openAICompatible
    case anthropic
    case gemini

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .openAICompatible: "OpenAI 兼容"
        case .anthropic: "Anthropic"
        case .gemini: "Google Gemini"
        }
    }

    public var defaultBaseURL: String {
        switch self {
        case .openAICompatible: "https://api.openai.com/v1"
        case .anthropic: "https://api.anthropic.com/v1"
        case .gemini: "https://generativelanguage.googleapis.com/v1beta"
        }
    }

    /// 设置界面里的地址示例。
    public var baseURLHint: String {
        switch self {
        case .openAICompatible: "例如 https://api.openai.com/v1 或 https://api.deepseek.com/v1"
        case .anthropic: "官方地址是 https://api.anthropic.com/v1"
        case .gemini: "官方地址是 https://generativelanguage.googleapis.com/v1beta"
        }
    }
}
