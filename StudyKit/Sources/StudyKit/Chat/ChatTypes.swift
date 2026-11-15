import Foundation

/// 消息的作者。
public enum ChatRole: String, Sendable, Codable, Equatable {
    case user
    case assistant
}

/// 发给服务商的一条消息，与具体协议无关。
public struct ChatMessage: Sendable, Equatable {
    public var role: ChatRole
    public var text: String

    public init(role: ChatRole, text: String) {
        self.role = role
        self.text = text
    }
}

/// 一次聊天请求，与具体协议无关。各协议的服务负责把它翻译成自己的请求格式。
public struct ChatRequest: Sendable, Equatable {
    /// 服务商那边的模型 ID，例如 `gpt-4o`。
    public var model: String
    /// 系统提示词。为空时不发送。
    public var systemPrompt: String?
    public var messages: [ChatMessage]

    public init(model: String, systemPrompt: String? = nil, messages: [ChatMessage]) {
        self.model = model
        self.systemPrompt = systemPrompt
        self.messages = messages
    }
}

/// 流式输出中的一个增量片段。流正常结束即表示生成完成。
public enum ChatStreamEvent: Sendable, Equatable {
    /// 正式回答的增量文本。
    case text(String)
    /// 思考过程的增量文本。
    case reasoning(String)
}

/// 某种 API 协议的聊天服务。
public protocol ChatService: Sendable {
    func streamChat(_ request: ChatRequest) -> AsyncThrowingStream<ChatStreamEvent, any Error>
}
