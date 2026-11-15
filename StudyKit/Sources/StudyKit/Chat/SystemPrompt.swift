import Foundation

public enum SystemPrompt {
    /// App 内置的格式规则，和渲染器（Renderer/）支持的语法对应。坐标图规则在 M3 加入。
    public static let builtInRules = """
    你的回答会显示在一个支持 Markdown 和 LaTeX 的学习应用里，请遵守下面的格式：
    - 用 Markdown 组织回答，可以使用标题、列表、表格和粗体。
    - 数学公式用 LaTeX。行内公式写成 $...$，独立成行的公式单独一行写成 $$...$$。不要用 \\( \\) 或 \\[ \\]。
    - 化学式和化学方程式用 mhchem 语法并放在公式里，例如 $\\ce{H2SO4}$、$\\ce{2H2 + O2 -> 2H2O}$、$\\ce{Fe^3+}$。
    - 代码放在标明语言的代码块里。
    - 金额等普通文字中的美元符号写成 \\$。
    """

    /// 内置格式规则加上用户提示词。
    public static func compose(customInstructions: String) -> String {
        let custom = customInstructions.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !custom.isEmpty else { return builtInRules }
        return builtInRules + "\n\n# 用户的说明\n" + custom
    }
}
