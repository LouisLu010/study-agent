import Foundation

public enum ChatServiceFactory {
    /// 检查并整理服务商的地址和 API Key。
    static func validate(baseURL: String, apiKey: String) throws -> (url: URL, key: String) {
        let key = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { throw ChatServiceError.missingAPIKey }

        let address = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: address),
              url.scheme?.lowercased() == "https",
              let host = url.host(), !host.isEmpty
        else { throw ChatServiceError.invalidBaseURL }
        return (url, key)
    }

    /// 根据服务商配置创建对应协议的聊天服务。
    public static func makeService(kind: ProviderKind, baseURL: String, apiKey: String) throws -> any ChatService {
        let (url, key) = try validate(baseURL: baseURL, apiKey: apiKey)

        switch kind {
        case .openAICompatible:
            return OpenAICompatibleService(baseURL: url, apiKey: key)
        case .anthropic:
            return AnthropicService(baseURL: url, apiKey: key)
        case .gemini:
            return GeminiService(baseURL: url, apiKey: key)
        }
    }
}
