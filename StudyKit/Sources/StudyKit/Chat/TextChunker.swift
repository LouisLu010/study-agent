import Foundation

/// 把很长的纯文本切成小段，分别交给 SwiftUI 排版。
/// 一个包含几万字的 `Text` 每次布局都要整体重排，展开思考过程时会明显卡顿。
public enum TextChunker {
    /// 按行累积，每段不超过 `maxLength` 个字符；单独一行超长时在中间切开。
    /// 没有超长行时，用 "\n" 把各段拼回去与原文相同。
    public static func split(_ text: String, maxLength: Int = 800) -> [String] {
        guard !text.isEmpty else { return [] }
        let limit = max(1, maxLength)
        var chunks: [String] = []
        var current = ""

        func flush() {
            if !current.isEmpty || chunks.isEmpty {
                chunks.append(current)
            }
            current = ""
        }

        let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
        for (index, lineSub) in lines.enumerated() {
            var line = Substring(lineSub)
            // 超长的一行先切成若干整段。
            while line.count > limit {
                if !current.isEmpty { flush() }
                let end = line.index(line.startIndex, offsetBy: limit)
                chunks.append(String(line[..<end]))
                line = line[end...]
            }
            let piece = String(line)
            if current.isEmpty {
                current = piece
            } else if current.count + 1 + piece.count <= limit {
                current += "\n" + piece
            } else {
                flush()
                current = piece
            }
            if index == lines.count - 1 { flush() }
        }
        return chunks
    }
}
