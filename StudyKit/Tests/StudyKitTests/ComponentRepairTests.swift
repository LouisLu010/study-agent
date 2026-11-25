import Foundation
import Testing
@testable import StudyKit

@Suite struct ComponentRepairTests {
    let reply = """
    先看图：

    ```graph
    {"functions": [{"expr": "x^2",}]}
    ```

    顶点是原点。
    """

    @Test func readsBlockByLineRange() {
        #expect(ComponentRepair.block(in: reply, lines: 2..<5) == "```graph\n{\"functions\": [{\"expr\": \"x^2\",}]}\n```")
        // 范围不是从代码块开头起的，不认。
        #expect(ComponentRepair.block(in: reply, lines: 3..<5) == nil)
        #expect(ComponentRepair.block(in: reply, lines: 2..<99) == nil)
    }

    @Test func extractsOnlyTheRequestedType() {
        let answer = "好的：\n\n```json\n{}\n```\n\n```graph\n{\"functions\": [{\"expr\": \"x^2\"}]}\n```\n多余的话"
        #expect(ComponentRepair.extractBlock(from: answer, type: "graph") == "```graph\n{\"functions\": [{\"expr\": \"x^2\"}]}\n```")
        #expect(ComponentRepair.extractBlock(from: "```graph\n{", type: "graph") == nil)
        #expect(ComponentRepair.extractBlock(from: "没有代码块", type: "graph") == nil)
    }

    @Test func splicesOnlyThatBlock() throws {
        let original = try #require(ComponentRepair.block(in: reply, lines: 2..<5))
        let fixed = "```graph\n{\"functions\": [{\"expr\": \"x^2\"}]}\n```"
        let result = ComponentRepair.splice(content: reply, original: original, replacement: fixed)
        #expect(result == reply.replacingOccurrences(of: original, with: fixed))
        #expect(result?.hasPrefix("先看图：") == true)
        #expect(result?.hasSuffix("顶点是原点。") == true)
        // 期间重新生成过，原来的代码块已经不在了。
        #expect(ComponentRepair.splice(content: "别的回答", original: original, replacement: fixed) == nil)
    }

    @Test func keepsListIndentation() {
        let content = "1. 第一步\n- ```graph\n  {bad}\n  ```\n2. 第二步"
        let original = "- ```graph\n  {bad}\n  ```"
        let result = ComponentRepair.splice(content: content, original: original, replacement: "```graph\n{}\n```")
        #expect(result == "1. 第一步\n- ```graph\n  {}\n  ```\n2. 第二步")
    }

    @Test func requestCarriesOnlyThisComponentSpec() {
        let request = ComponentRepair.request(
            model: "m", type: "quiz", brokenBlock: "```quiz\n{}\n```", error: "缺少 questions", reply: reply, question: "出题"
        )
        #expect(request.systemPrompt?.contains("（quiz）") == true)
        #expect(request.systemPrompt?.contains("（geometry）") == false)
        #expect(request.messages.count == 1)
        #expect(request.messages[0].text.contains("缺少 questions"))
    }
}
