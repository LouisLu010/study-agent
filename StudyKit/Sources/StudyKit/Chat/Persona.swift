import Foundation

/// 人格：App 内置的一种讲解风格。内容写在 `Prompts/personas.json` 里，App 和 tools/eval 读同一份，用户只能选不能改。
public struct Persona: Identifiable, Hashable, Sendable, Decodable {
    public let id: String
    public let name: String
    /// 选择人格时显示的一句话。
    public let summary: String
    /// 加进系统提示词的说明。"标准"人格为空，不加任何内容。
    public let prompt: String

    public static let standardID = "standard"

    /// 所有内置人格，第一个是"标准"。
    public static let all: [Persona] = load()

    public static var standard: Persona {
        all.first { $0.id == standardID } ?? Persona(id: standardID, name: "标准", summary: "", prompt: "")
    }

    /// 按 ID 找人格；空字符串或已经不存在的 ID 返回 nil。
    public static func find(_ id: String) -> Persona? {
        all.first { $0.id == id }
    }

    /// 会话实际使用的人格：会话自己选过就用会话的，否则用默认人格，默认人格也找不到时用"标准"。
    public static func resolve(conversationID: String, defaultID: String) -> Persona {
        find(conversationID) ?? find(defaultID) ?? standard
    }

    public init(id: String, name: String, summary: String, prompt: String) {
        self.id = id
        self.name = name
        self.summary = summary
        self.prompt = prompt
    }

    private static func load() -> [Persona] {
        guard let url = Bundle.module.url(forResource: "personas", withExtension: "json", subdirectory: "Prompts"),
              let data = try? Data(contentsOf: url),
              let list = try? JSONDecoder().decode([Persona].self, from: data),
              !list.isEmpty
        else {
            assertionFailure("缺少或无法解析 Prompts/personas.json")
            return [Persona(id: standardID, name: "标准", summary: "", prompt: "")]
        }
        return list
    }
}
