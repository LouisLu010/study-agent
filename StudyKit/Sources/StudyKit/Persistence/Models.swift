import Foundation
import SwiftData

// 所有模型都遵守 CloudKit 的约束：属性有默认值或可选、没有唯一约束、关系都可选。
// 这样以后开启 iCloud 同步时不需要迁移数据（见 docs/adr/0004）。

/// 服务商：一个大模型 API 来源。API Key 不存在这里，而是存在钥匙串里（见 `KeychainStore`）。
@Model
public final class Provider {
    public var id: UUID = UUID()
    public var name: String = ""
    public var kindRaw: String = "openAICompatible"
    public var baseURL: String = ""
    public var createdAt: Date = Date()

    @Relationship(deleteRule: .cascade, inverse: \ChatModel.provider)
    public var models: [ChatModel]? = []

    public init(name: String, kind: ProviderKind, baseURL: String) {
        self.name = name
        self.kindRaw = kind.rawValue
        self.baseURL = baseURL
    }

    public var kind: ProviderKind {
        get { ProviderKind(rawValue: kindRaw) ?? .openAICompatible }
        set { kindRaw = newValue.rawValue }
    }

    public var sortedModels: [ChatModel] {
        (models ?? []).sorted { $0.createdAt < $1.createdAt }
    }
}

/// 模型：某个服务商下的一个具体大模型。
@Model
public final class ChatModel {
    public var id: UUID = UUID()
    /// 服务商那边的模型 ID，例如 `gpt-4o`。
    public var modelID: String = ""
    /// 显示名称。为空时显示模型 ID。
    public var displayName: String = ""
    public var supportsImages: Bool = false
    /// 是否支持服务商自带的联网搜索（见 docs/adr/0011）。
    public var supportsWebSearch: Bool = false
    /// OpenAI 兼容协议下的搜索格式（`WebSearchDialect`）。空字符串表示自动判断。
    public var webSearchDialectRaw: String = ""
    /// 手动填写的单价（人民币 / 百万 token），优先于内置价格表。没填时为 nil。
    public var customInputPrice: Double?
    public var customOutputPrice: Double?
    /// 思考强度。空字符串表示使用服务商的默认值。
    public var reasoningEffortRaw: String = ""
    public var createdAt: Date = Date()

    public var provider: Provider?

    @Relationship(deleteRule: .nullify, inverse: \Conversation.model)
    public var conversations: [Conversation]? = []

    public init(modelID: String, displayName: String = "", supportsImages: Bool = false) {
        self.modelID = modelID
        self.displayName = displayName
        self.supportsImages = supportsImages
    }

    public var name: String {
        let trimmed = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? modelID : trimmed
    }

    /// 估算费用用的单价：手动填写的优先，否则查内置价格表。都没有时返回 nil。
    public func price(in table: PriceTable = .builtIn) -> ModelPrice? {
        let builtIn = table.price(for: modelID)
        if let input = customInputPrice, let output = customOutputPrice {
            return ModelPrice(
                input: input,
                output: output,
                currency: .cny,
                webSearchPer1000: builtIn?.webSearchPer1000,
                webSearchCurrency: builtIn?.webSearchCurrency
            )
        }
        return builtIn
    }

    public var reasoningEffort: ReasoningEffort? {
        get { ReasoningEffort(rawValue: reasoningEffortRaw) }
        set { reasoningEffortRaw = newValue?.rawValue ?? "" }
    }

    /// 实际使用的搜索格式（只对 OpenAI 兼容协议有意义）。
    public var webSearchDialect: WebSearchDialect {
        WebSearchDialect.resolve(raw: webSearchDialectRaw, modelID: modelID, baseURL: provider?.baseURL ?? "")
    }
}

/// 会话：用户与模型之间的一次完整对话。
@Model
public final class Conversation {
    public static let defaultTitle = "新会话"

    public var id: UUID = UUID()
    public var title: String = "新会话"
    /// 标题还没有被用户手动改过时为 true，第一轮回答后会自动生成标题。
    public var titleIsAutomatic: Bool = true
    /// 会话提示词：只对这个会话生效，接在用户提示词后面发送。
    public var instructions: String = ""
    /// 输入框旁的"联网"开关，按会话记住。模型不支持联网搜索时不生效。
    public var webSearchEnabled: Bool = false
    public var createdAt: Date = Date()
    public var updatedAt: Date = Date()

    public var model: ChatModel?

    @Relationship(deleteRule: .cascade, inverse: \Message.conversation)
    public var messages: [Message]? = []

    public init(title: String = "新会话") {
        self.title = title
    }

    /// 整个会话的用量合计。
    public var usageTotal: (input: Int, output: Int, cost: Double?, searches: Int) {
        var input = 0
        var output = 0
        var cost: Double?
        var searches = 0
        for message in messages ?? [] where message.role == .assistant {
            input += message.inputTokens ?? 0
            output += message.outputTokens ?? 0
            if let value = message.costCNY { cost = (cost ?? 0) + value }
            searches += message.webSearch?.effectiveCount ?? 0
        }
        return (input, output, cost, searches)
    }

    public var sortedMessages: [Message] {
        (messages ?? []).sorted { $0.index < $1.index }
    }

    /// 发给模型的历史消息。生成失败或还在生成中的消息不发送；停止和被系统中断的回答按已经写出的部分发送。
    public func chatHistory() -> [ChatMessage] {
        sortedMessages.compactMap { message in
            let images = message.imageData
            guard message.status == .complete || message.status == .stopped || message.status == .interrupted,
                  !message.content.isEmpty || !images.isEmpty
            else { return nil }
            return ChatMessage(role: message.role, text: message.content, images: images)
        }
    }
}

public enum MessageStatus: String, Sendable {
    case complete
    case streaming
    case failed
    /// 用户点了停止。
    case stopped
    /// 生成到一半被系统打断（切到别的 App 后被挂起，或者 App 被关掉）。保留已经写出的部分，可以继续生成。
    case interrupted
}

/// 消息：会话中的一条发言。
@Model
public final class Message {
    public var id: UUID = UUID()
    public var roleRaw: String = "user"
    public var content: String = ""
    /// 思考过程。
    public var reasoning: String = ""
    /// 组件状态，JSON 对象：{ 组件键: 状态 }。不发给模型。
    public var componentStateJSON: String = ""
    /// 这条回答的输入和输出 token 数。服务商没有返回时为 nil。
    public var inputTokens: Int?
    public var outputTokens: Int?
    /// 输入里命中缓存的 token 数（已经算在 inputTokens 里）。服务商没给出时为 nil。
    public var cachedInputTokens: Int?
    /// 生成完成时按当时模型的单价估算的费用（人民币）。没有价格时为 nil。
    public var costCNY: Double?
    /// 重新生成产生的所有版本（`ReplyVersions` 的 JSON）。只有一个版本时为空。
    public var versionsJSON: String = ""
    /// 联网搜索记录（`WebSearchRecord` 的 JSON）：搜索词、出处、搜索次数。没有搜索时为空。
    public var webSearchJSON: String = ""
    public var statusRaw: String = "complete"
    public var errorText: String?
    /// 生成这条回答的模型名（显示在回答上方）。第六版之前的回答为空。
    public var modelName: String = ""
    /// 在会话中的顺序。
    public var index: Int = 0
    public var createdAt: Date = Date()

    public var conversation: Conversation?

    @Relationship(deleteRule: .cascade, inverse: \Attachment.message)
    public var attachments: [Attachment]? = []

    public init(role: ChatRole, content: String = "", status: MessageStatus = .complete, index: Int) {
        self.roleRaw = role.rawValue
        self.content = content
        self.statusRaw = status.rawValue
        self.index = index
    }

    public var role: ChatRole {
        get { ChatRole(rawValue: roleRaw) ?? .user }
        set { roleRaw = newValue.rawValue }
    }

    public var status: MessageStatus {
        get { MessageStatus(rawValue: statusRaw) ?? .complete }
        set { statusRaw = newValue.rawValue }
    }

    public var sortedAttachments: [Attachment] {
        (attachments ?? []).sorted { $0.index < $1.index }
    }

    /// 按顺序排列的图片（JPEG）。
    public var imageData: [Data] {
        sortedAttachments.compactMap(\.data)
    }

    /// 这条回答的联网搜索记录。没有搜索时为 nil。
    public var webSearch: WebSearchRecord? {
        WebSearchRecord.decode(webSearchJSON)
    }
}

/// 用户消息附带的一张图片，已压缩成 JPEG。
@Model
public final class Attachment {
    public var id: UUID = UUID()
    @Attribute(.externalStorage) public var data: Data?
    public var index: Int = 0
    public var createdAt: Date = Date()

    public var message: Message?

    public init(data: Data, index: Int) {
        self.data = data
        self.index = index
    }
}
