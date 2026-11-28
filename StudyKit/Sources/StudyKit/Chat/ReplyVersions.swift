import Foundation

/// 一条模型消息的一个版本（见 docs/adr/0008）。
public struct ReplyVersion: Codable, Equatable, Sendable {
    public var content: String
    public var reasoning: String
    public var componentStateJSON: String
    public var statusRaw: String
    public var errorText: String?
    public var inputTokens: Int?
    public var outputTokens: Int?
    /// 旧版本没有这个字段，解码为 nil。
    public var cachedInputTokens: Int?
    public var costCNY: Double?
    /// 联网搜索记录。旧版本没有这个字段，解码为 nil。
    public var webSearchJSON: String?
    /// 旧快照没有模型名，无法从其他版本推断，显示为空。
    public var modelName: String?

    public init(
        content: String = "",
        reasoning: String = "",
        componentStateJSON: String = "",
        statusRaw: String = MessageStatus.complete.rawValue,
        errorText: String? = nil,
        inputTokens: Int? = nil,
        outputTokens: Int? = nil,
        cachedInputTokens: Int? = nil,
        costCNY: Double? = nil,
        webSearchJSON: String? = nil,
        modelName: String? = nil
    ) {
        self.content = content
        self.reasoning = reasoning
        self.componentStateJSON = componentStateJSON
        self.statusRaw = statusRaw
        self.errorText = errorText
        self.inputTokens = inputTokens
        self.outputTokens = outputTokens
        self.cachedInputTokens = cachedInputTokens
        self.costCNY = costCNY
        self.webSearchJSON = webSearchJSON
        self.modelName = modelName
    }
}

/// 所有版本和当前选中的是哪一个。消息上的 content 等字段始终是当前版本的内容，
/// 这里只在有多个版本时才保存，序列化成 `Message.versionsJSON`。
public struct ReplyVersions: Codable, Equatable, Sendable {
    public var items: [ReplyVersion]
    public var current: Int

    public init(items: [ReplyVersion], current: Int) {
        self.items = items
        self.current = max(0, min(current, items.count - 1))
    }

    public static func decode(_ json: String) -> ReplyVersions? {
        guard !json.isEmpty,
              let value = try? JSONDecoder().decode(ReplyVersions.self, from: Data(json.utf8)),
              !value.items.isEmpty
        else { return nil }
        return ReplyVersions(items: value.items, current: value.current)
    }

    public func encode() -> String {
        guard items.count > 1, let data = try? JSONEncoder().encode(self) else { return "" }
        return String(decoding: data, as: UTF8.self)
    }
}

extension Message {
    public var versionCount: Int {
        ReplyVersions.decode(versionsJSON)?.items.count ?? 1
    }

    /// 当前版本是第几个（从 0 开始）。
    public var currentVersion: Int {
        ReplyVersions.decode(versionsJSON)?.current ?? 0
    }

    var snapshot: ReplyVersion {
        ReplyVersion(
            content: content,
            reasoning: reasoning,
            componentStateJSON: componentStateJSON,
            statusRaw: statusRaw,
            errorText: errorText,
            inputTokens: inputTokens,
            outputTokens: outputTokens,
            cachedInputTokens: cachedInputTokens,
            costCNY: costCNY,
            webSearchJSON: webSearchJSON.isEmpty ? nil : webSearchJSON,
            modelName: modelName
        )
    }

    func apply(_ version: ReplyVersion) {
        content = version.content
        reasoning = version.reasoning
        componentStateJSON = version.componentStateJSON
        statusRaw = version.statusRaw
        errorText = version.errorText
        inputTokens = version.inputTokens
        outputTokens = version.outputTokens
        cachedInputTokens = version.cachedInputTokens
        costCNY = version.costCNY
        webSearchJSON = version.webSearchJSON ?? ""
        modelName = version.modelName ?? ""
    }

    /// 重新生成前调用：有内容的当前版本保留下来，消息清空，准备写入新版本。
    /// 失败或空的当前版本直接被新版本替换，不保留。
    public func beginNewVersion() {
        var versions = ReplyVersions.decode(versionsJSON) ?? ReplyVersions(items: [snapshot], current: 0)
        versions.items[versions.current] = snapshot
        let keep = !content.isEmpty && status != .failed
        if !keep {
            versions.items.remove(at: versions.current)
        }
        versions.items.append(ReplyVersion(statusRaw: MessageStatus.streaming.rawValue))
        versions.current = versions.items.count - 1
        versionsJSON = versions.encode()
        apply(versions.items[versions.current])
    }

    /// 新版本生成结束（完成、停止或失败）后调用，把结果记进版本列表。
    public func finishVersion() {
        guard var versions = ReplyVersions.decode(versionsJSON) else { return }
        versions.items[versions.current] = snapshot
        versionsJSON = versions.encode()
    }

    /// 切换到另一个版本。当前版本的组件状态会先保存下来。
    public func selectVersion(_ index: Int) {
        guard var versions = ReplyVersions.decode(versionsJSON),
              versions.items.indices.contains(index), index != versions.current
        else { return }
        versions.items[versions.current] = snapshot
        versions.current = index
        versionsJSON = versions.encode()
        apply(versions.items[index])
    }

    /// 发新消息时调用：只保留当前选中的版本，删除其他版本。
    public func keepOnlyCurrentVersion() {
        versionsJSON = ""
    }
}
