import Foundation
import SwiftData
import Testing
@testable import StudyKit

@MainActor
@Suite struct ReplyVersionsTests {
    let container: ModelContainer

    init() throws {
        container = try ModelContainer(
            for: Provider.self, ChatModel.self, Conversation.self, Message.self, Attachment.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
    }

    private func reply(_ text: String) -> Message {
        let message = Message(role: .assistant, content: text, index: 1)
        container.mainContext.insert(message)
        return message
    }

    /// 模拟一次重新生成：开始新版本、写入内容、结束。
    private func regenerate(_ message: Message, to text: String, status: MessageStatus = .complete) {
        message.beginNewVersion()
        #expect(message.content.isEmpty)
        #expect(message.status == .streaming)
        message.content = text
        message.status = status
        message.finishVersion()
    }

    @Test func singleReplyHasOneVersion() {
        let message = reply("第一版")
        #expect(message.versionCount == 1)
        #expect(message.versionsJSON.isEmpty)
    }

    @Test func regenerateKeepsOldVersions() {
        let message = reply("第一版")
        message.componentStateJSON = #"{"c0":{"a":2}}"#
        regenerate(message, to: "第二版")
        regenerate(message, to: "第三版")
        #expect(message.versionCount == 3)
        #expect(message.currentVersion == 2)
        #expect(message.content == "第三版")
        #expect(message.componentStateJSON.isEmpty)

        message.selectVersion(0)
        #expect(message.content == "第一版")
        #expect(message.componentStateJSON == #"{"c0":{"a":2}}"#)
        #expect(message.currentVersion == 0)
        message.selectVersion(2)
        #expect(message.content == "第三版")
    }

    @Test func switchingSavesComponentStateOfCurrentVersion() {
        let message = reply("第一版")
        regenerate(message, to: "第二版")
        message.componentStateJSON = #"{"c0":{"revealed":3}}"#
        message.selectVersion(0)
        message.selectVersion(1)
        #expect(message.componentStateJSON == #"{"c0":{"revealed":3}}"#)
    }

    @Test func failedVersionIsReplacedNotKept() {
        let message = reply("第一版")
        regenerate(message, to: "", status: .failed)
        #expect(message.versionCount == 2)
        // 失败的版本可以切回原来的版本
        message.selectVersion(0)
        #expect(message.content == "第一版")
        message.selectVersion(1)
        // 在失败的版本上重试，失败的版本被替换
        regenerate(message, to: "重试成功")
        #expect(message.versionCount == 2)
        message.selectVersion(0)
        #expect(message.content == "第一版")
    }

    @Test func failedOnlyReplyIsReplaced() {
        let message = reply("")
        message.status = .failed
        regenerate(message, to: "成功")
        #expect(message.versionCount == 1)
        #expect(message.content == "成功")
    }

    @Test func keepOnlyCurrentVersion() {
        let message = reply("第一版")
        regenerate(message, to: "第二版")
        message.selectVersion(0)
        message.keepOnlyCurrentVersion()
        #expect(message.versionCount == 1)
        #expect(message.content == "第一版")
    }

    @Test func malformedJSONIsIgnored() {
        #expect(ReplyVersions.decode("not json") == nil)
        #expect(ReplyVersions.decode(#"{"items":[],"current":0}"#) == nil)
    }

    @Test func switchingVersionsRestoresTheirModelNames() {
        let message = reply("第一版")
        message.modelName = "Model A"
        message.beginNewVersion()
        message.content = "第二版"
        message.modelName = "Model B"
        message.status = .complete
        message.finishVersion()
        message.selectVersion(0)
        #expect(message.modelName == "Model A")
        message.selectVersion(1)
        #expect(message.modelName == "Model B")
    }

    @Test func legacyVersionsDoNotBorrowAnotherModelsName() throws {
        let legacy = #"{"items":[{"content":"旧回答","reasoning":"","componentStateJSON":"","statusRaw":"complete"},{"content":"新回答","reasoning":"","componentStateJSON":"","statusRaw":"complete","modelName":"Model B"}],"current":1}"#
        let versions = try #require(ReplyVersions.decode(legacy))
        #expect(versions.items[0].modelName == nil)
        let message = reply("新回答")
        message.modelName = "Model B"
        message.versionsJSON = legacy
        message.selectVersion(0)
        #expect(message.content == "旧回答")
        #expect(message.modelName.isEmpty)
        message.selectVersion(1)
        #expect(message.modelName == "Model B")
    }
}

@Suite struct ConversationInstructionsTests {
    @Test func appendsConversationInstructionsLast() {
        let prompt = SystemPrompt.compose(customInstructions: "我是高二学生", conversationInstructions: " 只讲物理 ", simpleMode: true)
        #expect(prompt == SystemPrompt.baseRules + "\n\n# 用户的说明\n我是高二学生\n\n# 这个会话的说明\n只讲物理")
        #expect(SystemPrompt.compose(customInstructions: "", conversationInstructions: "  ", simpleMode: true) == SystemPrompt.baseRules)
    }

    @Test func personaGoesBeforeUserInstructions() throws {
        let persona = try #require(Persona.find("socratic"))
        let prompt = SystemPrompt.compose(customInstructions: "我是高二学生", conversationInstructions: "只讲物理", simpleMode: true, persona: persona)
        #expect(prompt == SystemPrompt.baseRules + "\n\n# 讲解方式\n" + persona.prompt + "\n\n# 用户的说明\n我是高二学生\n\n# 这个会话的说明\n只讲物理")
        // "标准"人格不加任何内容。
        #expect(SystemPrompt.compose(customInstructions: "", simpleMode: true, persona: .standard) == SystemPrompt.baseRules)
    }
}

@Suite struct PersonaTests {
    @Test func builtInPersonasLoad() {
        #expect(Persona.all.first?.id == Persona.standardID)
        #expect(Persona.all.map(\.id) == ["standard", "stepwise", "socratic", "cram", "grader"])
        #expect(Persona.all.dropFirst().allSatisfy { !$0.prompt.isEmpty && !$0.name.isEmpty })
        #expect(Persona.standard.prompt.isEmpty)
    }

    @Test func conversationChoiceWinsOverDefault() {
        #expect(Persona.resolve(conversationID: "cram", defaultID: "socratic").id == "cram")
        #expect(Persona.resolve(conversationID: "", defaultID: "socratic").id == "socratic")
        #expect(Persona.resolve(conversationID: "gone", defaultID: "").id == Persona.standardID)
    }
}

@Suite struct ImagePlaceholderTests {
    @Test func imagesBecomeTextMarks() {
        let message = ChatMessage(role: .user, text: "这道题怎么做", images: [Data([1]), Data([2])])
        let stripped = message.replacingImagesWithPlaceholders()
        #expect(stripped.images.isEmpty)
        #expect(stripped.text == "[图片] [图片]\n这道题怎么做")
        #expect(ChatMessage(role: .user, text: "", images: [Data([1])]).replacingImagesWithPlaceholders().text == "[图片]")
        #expect(ChatMessage(role: .user, text: "hi").replacingImagesWithPlaceholders() == ChatMessage(role: .user, text: "hi"))
    }
}
