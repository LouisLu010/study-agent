import Foundation

public enum ChatErrorDescription {
    /// 生成失败时显示给用户的说明。网络错误单独说明，其他错误用各自的描述。
    public static func describe(_ error: any Error) -> String {
        if let urlError = error as? URLError {
            switch urlError.code {
            case .notConnectedToInternet, .networkConnectionLost, .dataNotAllowed:
                return "网络连接已断开，请检查网络后重试。"
            case .timedOut:
                return "请求超时，服务商太久没有响应。"
            case .cannotFindHost, .cannotConnectToHost, .dnsLookupFailed:
                return "无法连接到服务商，请检查 API 地址是否正确。"
            case .secureConnectionFailed, .serverCertificateUntrusted, .serverCertificateHasBadDate:
                return "和服务商建立安全连接失败。"
            default:
                return "网络错误：\(urlError.localizedDescription)"
            }
        }
        return error.localizedDescription
    }
}

public enum ChatServiceError: Error, Equatable, LocalizedError {
    case missingAPIKey
    case invalidBaseURL
    case invalidResponse
    case http(status: Int, message: String?)
    case server(message: String)

    public var errorDescription: String? {
        switch self {
        case .missingAPIKey:
            return "这个服务商还没有填写 API Key。"
        case .invalidBaseURL:
            return "服务商的 API 地址无效，需要以 https:// 开头。"
        case .invalidResponse:
            return "服务商返回了无法识别的数据。"
        case let .http(status, message):
            let reason = switch status {
            case 401, 403: "API Key 无效或没有权限"
            case 404: "接口地址或模型 ID 不存在"
            case 429: "请求过于频繁或额度已用完"
            case 500...599: "服务商服务器出错"
            default: "请求失败"
            }
            if let message, !message.isEmpty {
                return "\(reason)（HTTP \(status)）：\(message)"
            }
            return "\(reason)（HTTP \(status)）。"
        case let .server(message):
            return "服务商返回错误：\(message)"
        }
    }
}
