import Foundation

/// 消息的作者。
public enum ChatRole: String, Sendable, Codable, Equatable {
    case user
    case assistant
}

/// 推理模型的思考强度。不设置时使用服务商的默认值。
public enum ReasoningEffort: String, CaseIterable, Identifiable, Sendable {
    case low
    case medium
    case high

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .low: "低"
        case .medium: "中"
        case .high: "高"
        }
    }
}

/// 发给服务商的一条消息，与具体协议无关。
public struct ChatMessage: Sendable, Equatable {
    public var role: ChatRole
    public var text: String
    /// JPEG 格式的图片。
    public var images: [Data]

    public init(role: ChatRole, text: String, images: [Data] = []) {
        self.role = role
        self.text = text
        self.images = images
    }
}

/// 一次聊天请求，与具体协议无关。各协议的服务负责把它翻译成自己的请求格式。
public struct ChatRequest: Sendable, Equatable {
    /// 服务商那边的模型 ID，例如 `gpt-4o`。
    public var model: String
    /// 系统提示词。为空时不发送。
    public var systemPrompt: String?
    public var messages: [ChatMessage]
    public var reasoningEffort: ReasoningEffort?

    public init(
        model: String,
        systemPrompt: String? = nil,
        messages: [ChatMessage],
        reasoningEffort: ReasoningEffort? = nil
    ) {
        self.model = model
        self.systemPrompt = systemPrompt
        self.messages = messages
        self.reasoningEffort = reasoningEffort
    }

    /// 去掉空白的系统提示词；为空时返回 nil。
    var trimmedSystemPrompt: String? {
        guard let system = systemPrompt?.trimmingCharacters(in: .whitespacesAndNewlines), !system.isEmpty else {
            return nil
        }
        return system
    }

    /// 合并相邻的同一作者的消息。Anthropic 和 Gemini 要求用户和模型的消息交替出现，
    /// 而某次生成失败后，会话里可能出现两条相邻的用户消息。
    var alternatingMessages: [ChatMessage] {
        var result: [ChatMessage] = []
        for message in messages {
            if let last = result.last, last.role == message.role {
                result[result.count - 1].text = [last.text, message.text]
                    .filter { !$0.isEmpty }
                    .joined(separator: "\n\n")
                result[result.count - 1].images += message.images
            } else {
                result.append(message)
            }
        }
        return result
    }
}

/// 流式输出中的一个增量片段。流正常结束即表示生成完成。
public enum ChatStreamEvent: Sendable, Equatable {
    /// 正式回答的增量文本。
    case text(String)
    /// 思考过程的增量文本。
    case reasoning(String)
    /// 用量。服务商可能分几次给出（例如先给输入、最后给输出），为 nil 的一项表示这次没有给出。
    case usage(input: Int?, output: Int?)
}

/// 某种 API 协议的聊天服务。
public protocol ChatService: Sendable {
    func streamChat(_ request: ChatRequest) -> AsyncThrowingStream<ChatStreamEvent, any Error>
}
