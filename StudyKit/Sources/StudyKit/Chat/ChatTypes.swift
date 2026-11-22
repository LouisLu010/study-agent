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
    /// 模型这一轮发起的工具调用（只在 assistant 消息里）。
    public var toolCalls: [ToolCall]
    /// 工具的执行结果（只在 user 消息里，跟在发起调用的 assistant 消息后面）。
    public var toolResults: [ToolResult]
    /// 这一轮的思考内容，调用工具时要按各家要求原样传回去（只在 assistant 消息里）。
    public var thinking: [ThinkingBlock]

    public init(
        role: ChatRole, text: String, images: [Data] = [],
        toolCalls: [ToolCall] = [], toolResults: [ToolResult] = [], thinking: [ThinkingBlock] = []
    ) {
        self.role = role
        self.text = text
        self.images = images
        self.toolCalls = toolCalls
        self.toolResults = toolResults
        self.thinking = thinking
    }
}

// MARK: - 工具调用（见 docs/adr/0014）

/// 声明给模型的一个工具。parameters 是 JSON Schema（type 为 object）。
public struct ToolDefinition: Sendable, Equatable {
    public var name: String
    public var description: String
    public var parameters: JSONValue

    public init(name: String, description: String, parameters: JSONValue) {
        self.name = name
        self.description = description
        self.parameters = parameters
    }
}

/// 模型发起的一次工具调用。
public struct ToolCall: Sendable, Equatable {
    /// 服务商给的调用 ID，工具结果要带上它。Gemini 旧版本不给，这时是 App 自己编的（`localIDPrefix` 开头）。
    public var id: String
    public var name: String
    /// 参数的 JSON 文字，原样保存，传回去时不改动。
    public var arguments: String
    /// Gemini 的 thought signature，要放回这次调用所在的位置。
    public var signature: String?

    public static let localIDPrefix = "local-"

    public init(id: String, name: String, arguments: String, signature: String? = nil) {
        self.id = id
        self.name = name
        self.arguments = arguments
        self.signature = signature
    }

    /// 解析后的参数；不是 JSON 对象时为空对象。
    public var input: JSONValue {
        if let value = JSONValue.parse(arguments), value.objectValue != nil { return value }
        return .object([:])
    }

    var hasServiceID: Bool { !id.hasPrefix(Self.localIDPrefix) }
}

/// 一次工具调用的结果。content 是交给模型看的文字（通常是 JSON）。
public struct ToolResult: Sendable, Equatable {
    public var callID: String
    public var name: String
    public var content: String

    public init(callID: String, name: String, content: String) {
        self.callID = callID
        self.name = name
        self.content = content
    }
}

/// 一段要原样传回的思考内容。
/// Anthropic：thinking 块（文字 + signature）或 redacted_thinking 块（data）。
/// Gemini：不在函数调用上的 thought signature（text 为空）。
/// OpenAI 兼容协议（DeepSeek）只用 text，拼成 reasoning_content。
public struct ThinkingBlock: Sendable, Equatable {
    public var text: String
    public var signature: String?
    public var redactedData: String?

    public init(text: String, signature: String? = nil, redactedData: String? = nil) {
        self.text = text
        self.signature = signature
        self.redactedData = redactedData
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
    /// 打开服务商自带的联网搜索（见 docs/adr/0011）。
    public var webSearch: Bool
    /// OpenAI 兼容协议下用哪家的搜索格式。其他协议忽略。
    public var webSearchDialect: WebSearchDialect
    /// App 内置的工具。为空时请求和第七版之前完全一样。
    public var tools: [ToolDefinition]

    public init(
        model: String,
        systemPrompt: String? = nil,
        messages: [ChatMessage],
        reasoningEffort: ReasoningEffort? = nil,
        webSearch: Bool = false,
        webSearchDialect: WebSearchDialect = .openAI,
        tools: [ToolDefinition] = []
    ) {
        self.model = model
        self.systemPrompt = systemPrompt
        self.messages = messages
        self.reasoningEffort = reasoningEffort
        self.webSearch = webSearch
        self.webSearchDialect = webSearchDialect
        self.tools = tools
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
                result[result.count - 1].toolCalls += message.toolCalls
                result[result.count - 1].toolResults += message.toolResults
                result[result.count - 1].thinking += message.thinking
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
    /// 输入里命中服务商缓存的 token 数（已经算在 usage 的 input 里）。命中缓存的部分单价低很多，
    /// 例如 DeepSeek 只有未命中的 1/50。服务商没有给出时不发这个事件。
    case cachedInput(Int)
    /// 模型开始一次联网搜索。搜索词这时可能还不知道（nil），之后会再给一次。
    case searching(query: String?)
    /// 搜索结果里的网页。
    case searchResults([WebSource])
    /// 正文里的引用。
    case citations([Citation])
    /// 到目前为止的搜索次数（累计值）。
    case searchCount(Int)
    /// 模型发起的一次工具调用，参数已经收完整。
    case toolCall(ToolCall)
    /// 一段要原样传回的思考内容（签名等）。文字本身已经通过 reasoning 事件给出过。
    case thinkingBlock(ThinkingBlock)
}

/// 某种 API 协议的聊天服务。
public protocol ChatService: Sendable {
    func streamChat(_ request: ChatRequest) -> AsyncThrowingStream<ChatStreamEvent, any Error>
}
