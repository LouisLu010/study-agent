import Testing
@testable import StudyKit

@Suite struct SSEParserTests {
    @Test func dispatchesOnBlankLine() {
        var parser = SSEParser()
        #expect(parser.feed("data: hello") == nil)
        #expect(parser.feed("") == SSEEvent(data: "hello"))
    }

    @Test func joinsMultipleDataLines() {
        var parser = SSEParser()
        _ = parser.feed("data: a")
        _ = parser.feed("data: b")
        #expect(parser.feed("") == SSEEvent(data: "a\nb"))
    }

    @Test func readsEventNameAndIgnoresComments() {
        var parser = SSEParser()
        #expect(parser.feed(": ping") == nil)
        _ = parser.feed("event: message_start")
        _ = parser.feed("data: {}")
        #expect(parser.feed("") == SSEEvent(event: "message_start", data: "{}"))
    }

    @Test func acceptsDataWithoutSpace() {
        var parser = SSEParser()
        _ = parser.feed("data:x")
        #expect(parser.feed("") == SSEEvent(data: "x"))
    }

    @Test func blankLineWithoutDataProducesNothing() {
        var parser = SSEParser()
        _ = parser.feed("event: ping")
        #expect(parser.feed("") == nil)
        _ = parser.feed("data: next")
        #expect(parser.feed("") == SSEEvent(data: "next"))
    }

    @Test func finishFlushesPendingEvent() {
        var parser = SSEParser()
        _ = parser.feed("data: tail")
        #expect(parser.finish() == SSEEvent(data: "tail"))
        #expect(parser.finish() == nil)
    }
}

@Suite struct LineSplitterTests {
    private func lines(_ text: String) -> [String] {
        var splitter = LineSplitter()
        var result: [String] = []
        for byte in text.utf8 {
            if let line = splitter.append(byte) {
                result.append(line)
            }
        }
        if let line = splitter.finish() {
            result.append(line)
        }
        return result
    }

    @Test func keepsBlankLinesAndHandlesCRLF() {
        #expect(lines("a\r\nb\n\nc") == ["a", "b", "", "c"])
    }

    @Test func decodesMultibyteCharacters() {
        #expect(lines("数学 ∫\n化学") == ["数学 ∫", "化学"])
    }
}
