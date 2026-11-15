import Foundation
import Testing
@testable import StudyKit

@Suite struct ConversationTitleTests {
    @Test func cleansModelOutput() {
        #expect(ConversationTitle.clean("求函数 y=x² 的导数") == "求函数 y=x² 的导数")
        #expect(ConversationTitle.clean("“二次函数的最值”") == "二次函数的最值")
        #expect(ConversationTitle.clean("标题：牛顿第二定律。") == "牛顿第二定律")
        #expect(ConversationTitle.clean("\n\n**化学平衡**\n解释：……") == "化学平衡")
        #expect(ConversationTitle.clean("   ") == nil)
    }

    @Test func limitsLength() {
        let long = String(repeating: "很", count: 50)
        #expect(ConversationTitle.clean(long)?.count == ConversationTitle.maxLength)
    }

    @Test func buildsShortRequest() {
        let request = ConversationTitle.request(model: "m", question: "什么是导数", answer: "导数是……")
        #expect(request.model == "m")
        #expect(request.reasoningEffort == nil)
        #expect(request.messages.count == 1)
        #expect(request.messages[0].text.contains("什么是导数"))
    }
}

@Suite struct ChatErrorDescriptionTests {
    @Test func describesNetworkErrors() {
        #expect(ChatErrorDescription.describe(URLError(.notConnectedToInternet)) == "网络连接已断开，请检查网络后重试。")
        #expect(ChatErrorDescription.describe(URLError(.timedOut)) == "请求超时，服务商太久没有响应。")
        #expect(ChatErrorDescription.describe(ChatServiceError.http(status: 401, message: "bad key"))
            == "API Key 无效或没有权限（HTTP 401）：bad key")
    }
}
