import Foundation
import StudyKit

enum UsageFormatting {
    static func tokens(_ count: Int) -> String {
        count.formatted(.number.grouping(.automatic))
    }

    /// 金额：大于 1 元保留两位小数，更小的保留两位有效数字，例如 ¥0.0034。
    static func cost(_ value: Double) -> String {
        if value >= 1 { return "约 ¥" + String(format: "%.2f", value) }
        if value <= 0 { return "约 ¥0" }
        let digits = max(2, Int(ceil(-log10(value))) + 1)
        return "约 ¥" + String(format: "%.\(min(digits, 6))f", value)
    }

    /// "输入 1,200（缓存 900）· 输出 350 tokens · 搜索 2 次 · 约 ¥0.012"，没有用量时返回 nil。
    static func summary(input: Int?, output: Int?, cost: Double?, searches: Int = 0, cached: Int? = nil) -> String? {
        guard input != nil || output != nil else { return nil }
        var text = "输入 \(tokens(input ?? 0))"
        if let cached, cached > 0 { text += "（缓存 \(tokens(cached))）" }
        text += " · 输出 \(tokens(output ?? 0)) tokens"
        if searches > 0 { text += " · 搜索 \(searches) 次" }
        if let cost { text += " · " + self.cost(cost) }
        return text
    }

    /// 单价，例如"输入 ¥2 / 输出 ¥8 每百万 tokens"。
    static func price(_ price: ModelPrice, usdToCNY: Double) -> String {
        let cny = price.inCNY(usdToCNY: usdToCNY)
        let fmt: (Double) -> String = { $0.formatted(.number.precision(.fractionLength(0...3))) }
        var text = "输入 ¥\(fmt(cny.input)) / 输出 ¥\(fmt(cny.output)) 每百万 tokens"
        if price.currency == .usd {
            text += "（官方 $\(fmt(price.input)) / $\(fmt(price.output))）"
        }
        if let cached = cny.cachedInput {
            text += "；命中缓存的输入 ¥\(fmt(cached))"
        }
        if let offPeak = price.offPeak {
            let hours = offPeak.peakHours.map { "\($0.first ?? 0)–\($0.last ?? 0)" }.joined(separator: "、")
            text += "；工作日 \(hours) 点以外 \(fmt(offPeak.factor * 10)) 折"
        }
        return text
    }
}
