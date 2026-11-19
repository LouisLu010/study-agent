import Foundation

/// 请模型给一道题（或一条回答）标科目和知识点。用于测验题没写 subject/topic、手动加入的错题和收藏。
public enum SubjectClassifier {
    public static func request(model: String, content: String) -> ChatRequest {
        let subjects = Subject.allCases.map(\.rawValue).joined(separator: "、")
        return ChatRequest(
            model: model,
            systemPrompt: """
            你负责给学习内容分类。只输出一个 JSON 对象，不要输出别的内容：
            {"subject": "科目", "topic": "知识点"}
            subject 只能是这几个之一：\(subjects)。topic 用不超过 12 个字概括具体知识点，例如"导数的运算""牛顿第二定律""物质的量"。
            """,
            messages: [ChatMessage(role: .user, text: String(content.prefix(1500)))]
        )
    }

    /// 解析模型的输出。允许 JSON 外面包着代码块或说明文字。
    public static func parse(_ raw: String) -> (subject: Subject, topic: String)? {
        guard let start = raw.firstIndex(of: "{"), let end = raw.lastIndex(of: "}"), start < end,
              let object = try? JSONSerialization.jsonObject(with: Data(raw[start...end].utf8)) as? [String: Any],
              let subject = Subject.normalize(object["subject"] as? String ?? "")
        else { return nil }
        let topic = (object["topic"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        return (subject, String(topic.prefix(20)))
    }
}
