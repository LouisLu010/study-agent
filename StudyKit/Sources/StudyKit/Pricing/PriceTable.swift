import Foundation

/// 一个模型的单价：每百万 token 多少钱。
public struct ModelPrice: Equatable, Sendable {
    public enum Currency: String, Codable, Sendable {
        case usd = "USD"
        case cny = "CNY"
    }

    public var input: Double
    public var output: Double
    public var currency: Currency

    public init(input: Double, output: Double, currency: Currency) {
        self.input = input
        self.output = output
        self.currency = currency
    }

    /// 换算成人民币单价。
    public func inCNY(usdToCNY rate: Double) -> ModelPrice {
        guard currency == .usd else { return self }
        return ModelPrice(input: input * rate, output: output * rate, currency: .cny)
    }

    /// 一次请求的估算费用（人民币）。
    public func costCNY(inputTokens: Int, outputTokens: Int, usdToCNY rate: Double) -> Double {
        let price = inCNY(usdToCNY: rate)
        return (Double(inputTokens) * price.input + Double(outputTokens) * price.output) / 1_000_000
    }
}

/// App 内置的官方价格表（`Pricing/prices.json`），随 App 版本更新。
public struct PriceTable: Sendable {
    private struct File: Decodable {
        struct Provider: Decodable {
            struct Model: Decodable {
                let ids: [String]
                let input: Double
                let output: Double
            }

            let name: String
            let currency: ModelPrice.Currency
            let models: [Model]
        }

        let updated: String
        let providers: [Provider]
    }

    public let updated: String
    private let prices: [String: ModelPrice]

    public static let builtIn: PriceTable = {
        guard let url = Bundle.module.url(forResource: "prices", withExtension: "json", subdirectory: "Pricing"),
              let data = try? Data(contentsOf: url),
              let table = try? PriceTable(json: data)
        else {
            assertionFailure("缺少价格表 Pricing/prices.json")
            return PriceTable(updated: "", prices: [:])
        }
        return table
    }()

    init(updated: String, prices: [String: ModelPrice]) {
        self.updated = updated
        self.prices = prices
    }

    public init(json: Data) throws {
        let file = try JSONDecoder().decode(File.self, from: json)
        var prices: [String: ModelPrice] = [:]
        for provider in file.providers {
            for model in provider.models {
                let price = ModelPrice(input: model.input, output: model.output, currency: provider.currency)
                for id in model.ids {
                    prices[Self.normalize(id)] = price
                }
            }
        }
        self.updated = file.updated
        self.prices = prices
    }

    /// 统一大小写，去掉中转服务常见的前缀，例如 `openai/gpt-6-sol`、`models/gemini-4-carbon`。
    static func normalize(_ modelID: String) -> String {
        var id = modelID.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if let slash = id.lastIndex(of: "/") {
            id = String(id[id.index(after: slash)...])
        }
        return id
    }

    /// 按模型 ID 查价格。完全匹配优先；其次允许带日期或版本后缀，例如 `claude-opus-5-5-20261001`、`qwen-plus@latest`。
    /// 匹配不上时返回 nil。
    public func price(for modelID: String) -> ModelPrice? {
        let id = Self.normalize(modelID)
        if let exact = prices[id] { return exact }
        let candidates = prices.keys.filter { key in
            guard id.hasPrefix(key), id.count > key.count else { return false }
            let rest = id.dropFirst(key.count)
            // 只接受日期或数字版本后缀，避免 gpt-6 误配 gpt-6-mini 这类不同模型。
            return rest.first == "@" || (rest.first == "-" && rest.dropFirst().first?.isNumber == true)
        }
        return candidates.max { $0.count < $1.count }.flatMap { prices[$0] }
    }
}
