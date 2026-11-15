import Foundation

/// 第一轮回答完成后，让模型给会话起一个简短的标题。
public enum ConversationTitle {
    static let maxLength = 20

    public static func request(model: String, question: String, answer: String) -> ChatRequest {
        ChatRequest(
            model: model,
            systemPrompt: "你负责给对话起标题。用不超过 15 个字概括用户的问题，只输出标题本身，不要加引号、标点或解释。",
            messages: [
                ChatMessage(
                    role: .user,
                    text: "用户的问题：\n\(question.prefix(1000))\n\n回答的开头：\n\(answer.prefix(500))"
                ),
            ]
        )
    }

    /// 清理模型返回的标题：取第一行，去掉引号、"标题："前缀和结尾标点，限制长度。
    public static func clean(_ raw: String) -> String? {
        var title = raw
            .split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .first { !$0.isEmpty } ?? ""
        for prefix in ["标题：", "标题:", "Title:", "title:"] where title.hasPrefix(prefix) {
            title = String(title.dropFirst(prefix.count))
        }
        let wrappers = CharacterSet(charactersIn: "\"'“”‘’「」《》*# ")
        title = title.trimmingCharacters(in: wrappers)
        title = title.trimmingCharacters(in: CharacterSet(charactersIn: "。.，,！!？?；;：:"))
        title = title.trimmingCharacters(in: wrappers)
        guard !title.isEmpty else { return nil }
        return String(title.prefix(maxLength))
    }

    /// 用户消息只有图片没有文字时，用来生成标题的问题描述。
    public static let imageOnlyQuestion = "（用户发送了一张图片）"
}
