import Foundation

/// 服务商接口返回的一个可用模型。
public struct RemoteModel: Sendable, Equatable, Identifiable {
    /// 调用时使用的模型 ID。
    public var id: String
    /// 服务商给的显示名称；没有时为空。
    public var displayName: String
    /// 是否支持图片输入。服务商没有提供这项信息时为 nil。
    public var supportsImages: Bool?

    public init(id: String, displayName: String = "", supportsImages: Bool? = nil) {
        self.id = id
        self.displayName = displayName
        self.supportsImages = supportsImages
    }
}

/// 从服务商的接口获取可用模型列表。
/// - OpenAI 兼容：`GET {base}/models`
/// - Anthropic：`GET {base}/models`，按 `after_id` 分页
/// - Gemini：`GET {base}/models`，按 `pageToken` 分页，只保留支持 generateContent 的模型
public enum ModelCatalog {
    public struct Page: Sendable, Equatable {
        public var models: [RemoteModel]
        /// 下一页的游标；没有下一页时为 nil。
        public var next: String?
    }

    static let maxPages = 10

    public static func fetch(
        kind: ProviderKind,
        baseURL: String,
        apiKey: String,
        session: URLSession = .shared
    ) async throws -> [RemoteModel] {
        let (url, key) = try ChatServiceFactory.validate(baseURL: baseURL, apiKey: apiKey)

        var models: [RemoteModel] = []
        var seen = Set<String>()
        var cursor: String?

        for _ in 0..<maxPages {
            let request = makeRequest(kind: kind, baseURL: url, apiKey: key, cursor: cursor)
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else { throw ChatServiceError.invalidResponse }
            guard (200..<300).contains(http.statusCode) else {
                let message = APIErrorMessage.extract(from: data)
                    ?? String(decoding: data.prefix(300), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
                throw ChatServiceError.http(status: http.statusCode, message: message.isEmpty ? nil : message)
            }

            let page = try parse(kind: kind, data: data)
            for model in page.models where seen.insert(model.id).inserted {
                models.append(model)
            }
            guard let next = page.next, !next.isEmpty, next != cursor else { break }
            cursor = next
        }

        // OpenAI 兼容接口返回的顺序没有规律，按 ID 排序；Anthropic 和 Gemini 保持服务商的顺序（新模型在前）。
        if kind == .openAICompatible {
            models.sort { $0.id.localizedStandardCompare($1.id) == .orderedAscending }
        }
        return models
    }

    // MARK: - 请求

    public static func makeRequest(kind: ProviderKind, baseURL: URL, apiKey: String, cursor: String?) -> URLRequest {
        var url = baseURL.appending(path: "models")
        switch kind {
        case .openAICompatible:
            break
        case .anthropic:
            var items = [URLQueryItem(name: "limit", value: "1000")]
            if let cursor { items.append(URLQueryItem(name: "after_id", value: cursor)) }
            url = url.appending(queryItems: items)
        case .gemini:
            var items = [URLQueryItem(name: "pageSize", value: "1000")]
            if let cursor { items.append(URLQueryItem(name: "pageToken", value: cursor)) }
            url = url.appending(queryItems: items)
        }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = 30
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        switch kind {
        case .openAICompatible:
            request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        case .anthropic:
            request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
            request.setValue(AnthropicService.apiVersion, forHTTPHeaderField: "anthropic-version")
        case .gemini:
            request.setValue(apiKey, forHTTPHeaderField: "x-goog-api-key")
        }
        return request
    }

    // MARK: - 解析

    private struct OpenAIList: Decodable {
        struct Item: Decodable {
            struct Architecture: Decodable {
                let inputModalities: [String]?

                enum CodingKeys: String, CodingKey {
                    case inputModalities = "input_modalities"
                }
            }

            let id: String
            /// OpenRouter 等服务商会提供名称。
            let name: String?
            /// OpenRouter 会提供输入类型。
            let architecture: Architecture?
        }

        let data: [Item]
    }

    private struct AnthropicList: Decodable {
        struct Item: Decodable {
            let id: String
            let displayName: String?

            enum CodingKeys: String, CodingKey {
                case id
                case displayName = "display_name"
            }
        }

        let data: [Item]
        let hasMore: Bool?
        let lastID: String?

        enum CodingKeys: String, CodingKey {
            case data
            case hasMore = "has_more"
            case lastID = "last_id"
        }
    }

    private struct GeminiList: Decodable {
        struct Item: Decodable {
            let name: String
            let displayName: String?
            let supportedGenerationMethods: [String]?
        }

        let models: [Item]?
        let nextPageToken: String?
    }

    public static func parse(kind: ProviderKind, data: Data) throws -> Page {
        let decoder = JSONDecoder()
        do {
            switch kind {
            case .openAICompatible:
                let list = try decoder.decode(OpenAIList.self, from: data)
                let models = list.data.map { item in
                    RemoteModel(
                        id: item.id,
                        displayName: item.name ?? "",
                        supportsImages: item.architecture?.inputModalities.map { $0.contains("image") }
                    )
                }
                return Page(models: models, next: nil)

            case .anthropic:
                let list = try decoder.decode(AnthropicList.self, from: data)
                // 目前的 Claude 模型都支持图片输入。
                let models = list.data.map {
                    RemoteModel(id: $0.id, displayName: $0.displayName ?? "", supportsImages: true)
                }
                return Page(models: models, next: list.hasMore == true ? list.lastID : nil)

            case .gemini:
                let list = try decoder.decode(GeminiList.self, from: data)
                let models = (list.models ?? []).compactMap { item -> RemoteModel? in
                    if let methods = item.supportedGenerationMethods, !methods.contains("generateContent") {
                        return nil
                    }
                    let id = item.name.hasPrefix("models/") ? String(item.name.dropFirst(7)) : item.name
                    // Gemini 的对话模型都支持图片输入。
                    return RemoteModel(id: id, displayName: item.displayName ?? "", supportsImages: true)
                }
                return Page(models: models, next: list.nextPageToken)
            }
        } catch {
            throw ChatServiceError.invalidResponse
        }
    }
}
