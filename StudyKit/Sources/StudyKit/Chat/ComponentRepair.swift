import Foundation

/// 只重新生成回答里格式有误的一个组件（第九版）：把出错的代码块和报错发给模型，拿回一个新的代码块，替换掉原来那一个。
/// 回答的其他部分不动，也不新增版本。
public enum ComponentRepair {
    /// 回答里用来给模型看上下文的字数上限（出错的组件前后各一半）。
    static let contextLimit = 3000

    /// 取出回答里第 `lines` 行（从 0 开始，不含上界）的代码块原文。这几行必须以代码块的开头一行起头，否则返回 nil。
    public static func block(in content: String, lines: Range<Int>) -> String? {
        let all = content.components(separatedBy: "\n")
        guard lines.lowerBound >= 0, lines.upperBound <= all.count, !lines.isEmpty else { return nil }
        let slice = Array(all[lines])
        guard fencePrefix(of: slice[0]) != nil else { return nil }
        return slice.joined(separator: "\n")
    }

    /// 发给模型的请求：只要一个修好的代码块。
    public static func request(
        model: String,
        type: String,
        brokenBlock: String,
        error: String,
        reply: String,
        question: String
    ) -> ChatRequest {
        let system = [
            "你负责修好学习 App 回答里的一个组件。组件是一个代码块，语言名是组件种类，内容是一个 JSON 对象，由 App 解析后绘制。",
            "下面是这种组件的格式说明：",
            spec(for: type),
            """
            # 要求
            - 只输出一个 ```\(type) 代码块，前后不要有任何文字。
            - 保持原来想表达的内容（同样的函数、图形、数据、题目或步骤），只改掉格式错误；原来的内容实在表达不了时，改成能表达的最接近的写法。
            - JSON 必须能直接解析：键和字符串用双引号，不要注释，不要多余的逗号；字符串里的反斜杠写两个，例如 "$\\\\frac{1}{2}$"。
            """,
        ].joined(separator: "\n\n")

        var user = ""
        let trimmedQuestion = question.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedQuestion.isEmpty {
            user += "用户的问题：\n" + String(trimmedQuestion.prefix(800)) + "\n\n"
        }
        user += "回答里这个组件前后的内容（组件的位置标成【要修的组件】）：\n" + context(of: brokenBlock, in: reply) + "\n\n"
        user += "出错的组件原文：\n" + brokenBlock + "\n\n"
        user += "App 解析时的报错：" + (error.isEmpty ? "（没有报错信息）" : error) + "\n\n"
        user += "请输出修好的 ```\(type) 代码块。"

        return ChatRequest(
            model: model,
            systemPrompt: system,
            messages: [ChatMessage(role: .user, text: user)]
        )
    }

    /// 从模型的回复里取出 `type` 种类的第一个代码块（含开头和结尾的 ``` 两行）。没有时返回 nil。
    public static func extractBlock(from reply: String, type: String) -> String? {
        let lines = reply.components(separatedBy: "\n")
        var index = 0
        while index < lines.count {
            let line = lines[index].trimmingCharacters(in: .whitespaces)
            if let marker = fenceMarker(line), language(of: line, marker: marker) == type.lowercased() {
                var end = index + 1
                while end < lines.count {
                    let closing = lines[end].trimmingCharacters(in: .whitespaces)
                    if closing.hasPrefix(marker), closing.allSatisfy({ $0 == marker.first }) { break }
                    end += 1
                }
                guard end < lines.count else { return nil }
                let body = lines[(index + 1)..<end].joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
                guard !body.isEmpty else { return nil }
                return "```\(type)\n" + body + "\n```"
            }
            index += 1
        }
        return nil
    }

    /// 把回答里的 `original` 换成 `replacement`。原来的代码块在列表或引用里时（开头一行前面有缩进或 "> "），
    /// 新代码块的每一行都加上同样的前缀。回答里已经找不到原来的代码块时返回 nil（例如期间重新生成过）。
    public static func splice(content: String, original: String, replacement: String) -> String? {
        guard let range = content.range(of: original),
              let firstLine = original.components(separatedBy: "\n").first,
              let prefix = fencePrefix(of: firstLine),
              let fence = firstLine.range(of: "```") ?? firstLine.range(of: "~~~")
        else { return nil }
        // 第一行原样保留列表符号，后面的行用对齐的前缀。
        let firstPrefix = String(firstLine[..<fence.lowerBound])
        let indented = replacement
            .components(separatedBy: "\n")
            .enumerated()
            .map { ($0.offset == 0 ? firstPrefix : prefix) + $0.element }
            .joined(separator: "\n")
        return content.replacingCharacters(in: range, with: indented)
    }

    // MARK: - 内部

    /// 代码块开头一行 ``` 或 ~~~ 前面的部分（缩进、引用的 "> "）。不是代码块开头时返回 nil。
    static func fencePrefix(of line: String) -> String? {
        guard let start = line.range(of: "```") ?? line.range(of: "~~~") else { return nil }
        let prefix = String(line[..<start.lowerBound])
        guard prefix.allSatisfy({ $0 == " " || $0 == ">" || $0 == "\t" || $0 == "-" || $0 == "*" || $0.isNumber || $0 == "." }) else {
            return nil
        }
        // 列表的 "- " "1. " 只出现在第一行，后面的行用同样宽度的空格对齐。
        return String(prefix.map { $0 == ">" ? ">" : " " })
    }

    private static func fenceMarker(_ line: String) -> String? {
        for character in ["`", "~"] {
            let run = line.prefix { String($0) == character }
            if run.count >= 3 { return String(run) }
        }
        return nil
    }

    private static func language(of line: String, marker: String) -> String {
        line.dropFirst(marker.count)
            .trimmingCharacters(in: .whitespaces)
            .split(separator: " ").first.map { $0.lowercased() } ?? ""
    }

    /// 内置提示词里这种组件那一节（`## …（type）` 到下一个 `## `），加上开头的通用写法。找不到时用全部组件规则。
    static func spec(for type: String) -> String {
        let rules = SystemPrompt.componentRules
        let sections = rules.components(separatedBy: "\n## ")
        guard let intro = sections.first,
              let section = sections.dropFirst().first(where: { $0.components(separatedBy: "\n").first?.contains("（\(type)）") == true })
        else { return rules }
        return intro + "\n\n## " + section
    }

    /// 出错的组件前后的回答原文，组件本身换成一个标记。
    static func context(of block: String, in reply: String) -> String {
        guard let range = reply.range(of: block) else { return String(reply.prefix(contextLimit)) }
        let half = contextLimit / 2
        let before = String(reply[..<range.lowerBound].suffix(half))
        let after = String(reply[range.upperBound...].prefix(half))
        return before + "【要修的组件】" + after
    }
}
