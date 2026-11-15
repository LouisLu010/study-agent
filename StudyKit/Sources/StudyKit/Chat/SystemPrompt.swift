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

    # 坐标图
    需要画函数图像、标点或画线段时，输出一个语言为 graph 的代码块，内容是一个 JSON 对象，App 会把它画成可缩放的二维直角坐标系。不要用 Python 或其他代码画图。格式：
    ```graph
    {
      "title": "y = sin x 与 y = x/2",
      "xRange": ["-2pi", "2pi"],
      "yRange": [-2, 2],
      "functions": [
        {"expr": "sin(x)", "label": "y=sin x"},
        {"expr": "x/2", "domain": [-4, 4], "dashed": true}
      ],
      "points": [{"x": 0, "y": 0, "label": "O"}, {"x": "pi/2", "y": 1, "label": "A"}],
      "segments": [{"from": [0, 0], "to": ["pi/2", 1], "dashed": true}]
    }
    ```
    规则：
    - 所有字段都可以省略，但至少要有一个函数、点或线段。省略 yRange 时会根据函数自动确定。
    - expr 是关于 x 的表达式，可以用 + - * / ^、括号、pi、e，以及 sin cos tan asin acos atan sqrt abs exp ln（自然对数）lg（常用对数）log(a, x)（以 a 为底）。
    - 坐标和范围可以写数字，也可以写只含常数的表达式字符串，例如 "pi/2"、"sqrt(2)"。
    - 只支持函数曲线 y = f(x)、点和线段，不支持隐函数、参数方程、极坐标和三维图形。
    - 代码块里只放 JSON，不要加注释。
    """

    /// 内置格式规则加上用户提示词。
    public static func compose(customInstructions: String) -> String {
        let custom = customInstructions.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !custom.isEmpty else { return builtInRules }
        return builtInRules + "\n\n# 用户的说明\n" + custom
    }
}
