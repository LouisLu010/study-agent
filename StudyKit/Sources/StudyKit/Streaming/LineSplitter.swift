import Foundation

/// 把字节流切成行，保留空行（SSE 用空行分隔事件，而 `AsyncBytes.lines` 会丢掉空行）。
/// 支持 `\n` 和 `\r\n` 两种换行。
public struct LineSplitter: Sendable {
    private var buffer: [UInt8] = []

    public init() {}

    /// 追加一个字节；遇到换行时返回完整的一行（不含换行符）。
    public mutating func append(_ byte: UInt8) -> String? {
        if byte == 0x0A {
            return flushLine()
        }
        buffer.append(byte)
        return nil
    }

    /// 流结束时调用，返回最后一行没有换行结尾的内容。
    public mutating func finish() -> String? {
        buffer.isEmpty ? nil : flushLine()
    }

    private mutating func flushLine() -> String {
        if buffer.last == 0x0D {
            buffer.removeLast()
        }
        let line = String(decoding: buffer, as: UTF8.self)
        buffer.removeAll(keepingCapacity: true)
        return line
    }
}
