import Foundation

/// 内置提示词。文字放在 `Prompts/` 下的 Markdown 文件里，App 和测试工具（tools/eval）读的是同一份。
public enum SystemPrompt {
    /// 基本格式规则：Markdown、公式、化学式。
    public static let baseRules = load("base")
    /// 组件的使用规则和格式说明。简洁模式下不发送。
    public static let componentRules = load("components")

    /// 内置规则、人格、用户提示词、会话提示词，按这个顺序拼接；用户自己写的说明排在后面，优先。
    public static func compose(
        customInstructions: String,
        conversationInstructions: String = "",
        simpleMode: Bool = false,
        persona: Persona? = nil
    ) -> String {
        var parts = [baseRules]
        if !simpleMode {
            parts.append(componentRules)
        }
        let personaPrompt = persona?.prompt.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !personaPrompt.isEmpty {
            parts.append("# 讲解方式\n" + personaPrompt)
        }
        let custom = customInstructions.trimmingCharacters(in: .whitespacesAndNewlines)
        if !custom.isEmpty {
            parts.append("# 用户的说明\n" + custom)
        }
        let conversation = conversationInstructions.trimmingCharacters(in: .whitespacesAndNewlines)
        if !conversation.isEmpty {
            parts.append("# 这个会话的说明\n" + conversation)
        }
        return parts.joined(separator: "\n\n")
    }

    static func load(_ name: String) -> String {
        guard let url = Bundle.module.url(forResource: name, withExtension: "md", subdirectory: "Prompts"),
              let text = try? String(contentsOf: url, encoding: .utf8)
        else {
            assertionFailure("缺少提示词文件 Prompts/\(name).md")
            return ""
        }
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
