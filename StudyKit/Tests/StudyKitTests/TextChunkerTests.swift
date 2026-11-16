import Testing
@testable import StudyKit

@Suite struct TextChunkerTests {
    @Test func keepsShortTextInOneChunk() {
        #expect(TextChunker.split("") == [])
        #expect(TextChunker.split("一行") == ["一行"])
        #expect(TextChunker.split("a\nb\n\nc") == ["a\nb\n\nc"])
    }

    @Test func groupsLinesUpToLimit() {
        let chunks = TextChunker.split("aaaa\nbbbb\ncccc", maxLength: 9)
        #expect(chunks == ["aaaa\nbbbb", "cccc"])
    }

    @Test func splitsVeryLongLines() {
        let chunks = TextChunker.split("abcdefghij\nxy", maxLength: 4)
        #expect(chunks == ["abcd", "efgh", "ij", "xy"])
    }

    @Test func joinsBackToOriginal() {
        let line = String(repeating: "思", count: 37)
        let text = (0..<200).map { "\($0) " + line }.joined(separator: "\n") + "\n\n结尾"
        let chunks = TextChunker.split(text, maxLength: 300)
        #expect(chunks.count > 10)
        #expect(chunks.allSatisfy { $0.count <= 300 })
        #expect(chunks.joined(separator: "\n") == text)
    }
}
