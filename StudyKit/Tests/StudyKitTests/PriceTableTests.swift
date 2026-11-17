import Foundation
import Testing
@testable import StudyKit

@Suite struct PriceTableTests {
    private let table = try! PriceTable(json: Data(#"""
    {"updated":"2026-11-15","providers":[
      {"name":"A","currency":"USD","models":[
        {"ids":["gpt-6-sol"],"input":2,"output":10},
        {"ids":["claude-opus-5-5"],"input":4,"output":20},
        {"ids":["gpt-6"],"input":1,"output":5}
      ]},
      {"name":"B","currency":"CNY","models":[{"ids":["deepseek-flash","deepseek-v4-flash"],"input":2,"output":8}]}
    ]}
    """#.utf8))

    @Test func matchesExactAndNormalizedIDs() {
        #expect(table.price(for: "gpt-6-sol") == ModelPrice(input: 2, output: 10, currency: .usd))
        #expect(table.price(for: " OpenAI/GPT-6-Sol ")?.input == 2)
        #expect(table.price(for: "models/claude-opus-5-5")?.output == 20)
        #expect(table.price(for: "deepseek-v4-flash")?.currency == .cny)
    }

    @Test func acceptsDateAndVersionSuffixesOnly() {
        #expect(table.price(for: "claude-opus-5-5-20261001")?.input == 4)
        #expect(table.price(for: "deepseek-flash@latest")?.input == 2)
        // 不同的模型不能误配
        #expect(table.price(for: "gpt-6-mini") == nil)
        #expect(table.price(for: "gpt-6-sol-pro") == nil)
        #expect(table.price(for: "unknown-model") == nil)
    }

    @Test func convertsAndEstimatesCost() {
        let usd = ModelPrice(input: 2, output: 10, currency: .usd)
        // 10 万输入 + 2 万输出，按 7.2 折算：(0.1 × 2 + 0.02 × 10) × 7.2 = 2.88
        #expect(abs(usd.costCNY(inputTokens: 100_000, outputTokens: 20_000, usdToCNY: 7.2) - 2.88) < 1e-9)
        let cny = ModelPrice(input: 2, output: 8, currency: .cny)
        #expect(abs(cny.costCNY(inputTokens: 1_000_000, outputTokens: 0, usdToCNY: 7.2) - 2) < 1e-9)
    }

    @Test func builtInTableLoads() {
        #expect(!PriceTable.builtIn.updated.isEmpty)
        #expect(PriceTable.builtIn.price(for: "claude-sonnet-5-5") != nil)
        #expect(PriceTable.builtIn.price(for: "deepseek-flash")?.currency == .cny)
    }
}
