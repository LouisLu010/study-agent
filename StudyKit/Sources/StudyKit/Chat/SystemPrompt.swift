import Foundation

public enum SystemPrompt {
    /// App 内置的格式规则。公式和化学式规则在 M2 加入，坐标图规则在 M3 加入。
    public static let builtInRules = """
    使用 Markdown 组织回答。
    """

    /// 内置格式规则加上用户提示词。
    public static func compose(customInstructions: String) -> String {
        let custom = customInstructions.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !custom.isEmpty else { return builtInRules }
        return builtInRules + "\n\n# 用户的说明\n" + custom
    }
}
