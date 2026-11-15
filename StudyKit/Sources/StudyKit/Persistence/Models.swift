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

    public var reasoningEffort: ReasoningEffort? {
        get { ReasoningEffort(rawValue: reasoningEffortRaw) }
        set { reasoningEffortRaw = newValue?.rawValue ?? "" }
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
    public var createdAt: Date = Date()
    public var updatedAt: Date = Date()

    public var model: ChatModel?

    @Relationship(deleteRule: .cascade, inverse: \Message.conversation)
    public var messages: [Message]? = []

    public init(title: String = "新会话") {
        self.title = title
    }

    public var sortedMessages: [Message] {
        (messages ?? []).sorted { $0.index < $1.index }
    }

    /// 发给模型的历史消息。生成失败或还在生成中的消息不发送。
    public func chatHistory() -> [ChatMessage] {
        sortedMessages.compactMap { message in
            let images = message.imageData
            guard message.status == .complete || message.status == .stopped,
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
    case stopped
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
    public var statusRaw: String = "complete"
    public var errorText: String?
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
