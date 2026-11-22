import Foundation

/// 一个模型的单价：每百万 token 多少钱。
public struct ModelPrice: Equatable, Sendable {
    public enum Currency: String, Codable, Sendable {
        case usd = "USD"
        case cny = "CNY"
    }

    /// 服务商的空闲时段折扣，例如 DeepSeek：北京时间工作日 9–12、14–18 点是高峰，其余时间半价。
    /// 不认法定节假日（那几天其实也是空闲时段），所以节假日会算贵一点。
    public struct OffPeak: Codable, Equatable, Sendable {
        /// 时区，例如 Asia/Shanghai。
        public var timeZone: String
        /// 高峰时段，[开始小时, 结束小时)，只在周一到周五。
        public var peakHours: [[Int]]
        /// 空闲时段的价格是高峰的几倍，例如 0.5。
        public var factor: Double

        public init(timeZone: String, peakHours: [[Int]], factor: Double) {
            self.timeZone = timeZone
            self.peakHours = peakHours
            self.factor = factor
        }

        /// 这个时刻的价格倍数：高峰 1，空闲 factor。
        public func multiplier(at date: Date) -> Double {
            var calendar = Calendar(identifier: .gregorian)
            guard let zone = TimeZone(identifier: timeZone) else { return 1 }
            calendar.timeZone = zone
            let weekday = calendar.component(.weekday, from: date)
            let hour = calendar.component(.hour, from: date)
            let workday = (2...6).contains(weekday)
            let peak = workday && peakHours.contains { $0.count == 2 && hour >= $0[0] && hour < $0[1] }
            return peak ? 1 : factor
        }
    }

    public var input: Double
    /// 命中缓存的输入单价。没有时按 input 算。
    public var cachedInput: Double?
    public var output: Double
    public var currency: Currency
    /// 空闲时段折扣。没有时不打折。
    public var offPeak: OffPeak?
    /// 联网搜索每 1000 次的价格。没有时为 nil，不计搜索费。
    public var webSearchPer1000: Double?
    /// 搜索单价的币种。手动填写 token 单价（人民币）时，搜索单价仍沿用价格表里的币种。
    public var webSearchCurrency: Currency

    public init(
        input: Double,
        output: Double,
        currency: Currency,
        webSearchPer1000: Double? = nil,
        webSearchCurrency: Currency? = nil,
        cachedInput: Double? = nil,
        offPeak: OffPeak? = nil
    ) {
        self.input = input
        self.cachedInput = cachedInput
        self.offPeak = offPeak
        self.output = output
        self.currency = currency
        self.webSearchPer1000 = webSearchPer1000
        self.webSearchCurrency = webSearchCurrency ?? currency
    }

    /// 换算成人民币单价。
    public func inCNY(usdToCNY rate: Double) -> ModelPrice {
        let tokenRate = currency == .usd ? rate : 1
        let searchRate = webSearchCurrency == .usd ? rate : 1
        return ModelPrice(
            input: input * tokenRate,
            output: output * tokenRate,
            currency: .cny,
            webSearchPer1000: webSearchPer1000.map { $0 * searchRate },
            webSearchCurrency: .cny,
            cachedInput: cachedInput.map { $0 * tokenRate },
            offPeak: offPeak
        )
    }

    /// 一次请求的估算费用（人民币），包括联网搜索的费用。cachedInputTokens 是 inputTokens 里命中缓存的部分；
    /// date 是请求的时间，用来判断是不是空闲时段。
    public func costCNY(
        inputTokens: Int, cachedInputTokens: Int = 0, outputTokens: Int, webSearches: Int = 0,
        usdToCNY rate: Double, at date: Date = .now
    ) -> Double {
        let price = inCNY(usdToCNY: rate)
        let cached = Double(min(max(0, cachedInputTokens), inputTokens))
        let miss = Double(inputTokens) - cached
        let input = miss * price.input + cached * (price.cachedInput ?? price.input)
        let tokens = (input + Double(outputTokens) * price.output) / 1_000_000 * (offPeak?.multiplier(at: date) ?? 1)
        let searches = Double(max(0, webSearches)) * (price.webSearchPer1000 ?? 0) / 1000
        return tokens + searches
    }
}

/// App 内置的官方价格表（`Pricing/prices.json`），随 App 版本更新。
public struct PriceTable: Sendable {
    private struct File: Decodable {
        struct Provider: Decodable {
            struct Model: Decodable {
                let ids: [String]
                let input: Double
                /// 命中缓存的输入单价。
                let cachedInput: Double?
                let output: Double
                /// 这个模型自己的搜索单价，优先于服务商的。
                let webSearchPer1000: Double?
            }

            let name: String
            let currency: ModelPrice.Currency
            /// 空闲时段折扣。
            let offPeak: ModelPrice.OffPeak?
            /// 联网搜索每 1000 次的价格（服务商币种）。
            let webSearchPer1000: Double?
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
                let price = ModelPrice(
                    input: model.input,
                    output: model.output,
                    currency: provider.currency,
                    webSearchPer1000: model.webSearchPer1000 ?? provider.webSearchPer1000,
                    cachedInput: model.cachedInput,
                    offPeak: provider.offPeak
                )
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
