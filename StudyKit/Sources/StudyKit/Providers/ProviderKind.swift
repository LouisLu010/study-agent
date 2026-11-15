import Foundation

/// 服务商使用的 API 协议。Anthropic 和 Gemini 在 M4 加入。
public enum ProviderKind: String, CaseIterable, Identifiable, Sendable {
    case openAICompatible

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .openAICompatible: "OpenAI 兼容"
        }
    }

    public var defaultBaseURL: String {
        switch self {
        case .openAICompatible: "https://api.openai.com/v1"
        }
    }
}
