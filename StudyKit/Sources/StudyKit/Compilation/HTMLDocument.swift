import Foundation

/// 一个宽松的 HTML 解析器，只用来从题库网页里取题目：标签树、属性、文字。
/// 不执行脚本，不处理样式；script、style、head 等的内容直接丢掉。
public final class HTMLNode: @unchecked Sendable {
    public enum Kind: Sendable {
        case element(String)
        case text(String)
    }

    public let kind: Kind
    public let attributes: [String: String]
    public private(set) var children: [HTMLNode] = []
    public private(set) weak var parent: HTMLNode?

    init(kind: Kind, attributes: [String: String] = [:], parent: HTMLNode?) {
        self.kind = kind
        self.attributes = attributes
        self.parent = parent
    }

    public var tag: String? {
        if case let .element(name) = kind { return name }
        return nil
    }

    public var textValue: String? {
        if case let .text(value) = kind { return value }
        return nil
    }

    public var className: String { attributes["class"] ?? "" }

    func append(_ child: HTMLNode) {
        children.append(child)
    }

    /// 所有文字连起来。
    public var text: String {
        if let textValue { return textValue }
        return children.map(\.text).joined()
    }

    /// 自己和所有后代元素，先序。
    public func descendants() -> [HTMLNode] {
        var result: [HTMLNode] = []
        var stack: [HTMLNode] = [self]
        while let node = stack.popLast() {
            guard node.tag != nil else { continue }
            result.append(node)
            stack.append(contentsOf: node.children.reversed())
        }
        return result
    }
}

public enum HTMLDocument {
    static let voidTags: Set<String> = ["img", "br", "hr", "meta", "link", "input", "source", "wbr", "col", "area", "base", "embed", "param", "track"]
    /// 内容整个丢掉的标签。
    static let skippedTags: Set<String> = ["script", "style", "noscript", "head", "svg", "template", "button", "select", "iframe", "textarea", "title"]

    /// 解析成一棵树，根节点是 `#root`。
    public static func parse(_ html: String) -> HTMLNode {
        let root = HTMLNode(kind: .element("#root"), parent: nil)
        var current = root
        let bytes = Array(html.utf8)
        var i = 0
        var textStart = 0

        func flushText(to end: Int) {
            guard end > textStart else { return }
            let raw = String(decoding: bytes[textStart..<end], as: UTF8.self)
            current.append(HTMLNode(kind: .text(decodeEntities(raw)), parent: current))
        }

        while i < bytes.count {
            guard bytes[i] == UInt8(ascii: "<"), i + 1 < bytes.count else { i += 1; continue }
            let next = bytes[i + 1]
            if next == UInt8(ascii: "!") || next == UInt8(ascii: "?") {
                flushText(to: i)
                if bytes[i...].starts(with: Array("<!--".utf8)) {
                    i = find(Array("-->".utf8), in: bytes, from: i + 4).map { $0 + 3 } ?? bytes.count
                } else {
                    i = (bytes[i...].firstIndex(of: UInt8(ascii: ">")) ?? bytes.count - 1) + 1
                }
                textStart = i
                continue
            }
            let isEnd = next == UInt8(ascii: "/")
            let nameStart = isEnd ? i + 2 : i + 1
            guard nameStart < bytes.count, isLetter(bytes[nameStart]) else { i += 1; continue }
            flushText(to: i)
            var j = nameStart
            while j < bytes.count, isNameChar(bytes[j]) { j += 1 }
            let name = String(decoding: bytes[nameStart..<j], as: UTF8.self).lowercased()
            let (attributes, close, selfClosing) = parseAttributes(bytes, from: j)
            i = close
            textStart = i

            if isEnd {
                // 关掉最近的同名元素；没有就忽略这个结束标签。
                var node: HTMLNode? = current
                while let candidate = node, candidate.tag != name { node = candidate.parent }
                if let matched = node, let parent = matched.parent { current = parent }
                continue
            }
            if skippedTags.contains(name) {
                // 跳到对应的结束标签。
                let endTag = Array("</\(name)".utf8)
                i = findCaseInsensitive(endTag, in: bytes, from: i).map { start in
                    (bytes[start...].firstIndex(of: UInt8(ascii: ">")) ?? bytes.count - 1) + 1
                } ?? bytes.count
                textStart = i
                continue
            }
            // <p> 和 <li> 遇到新的同类标签时自动结束上一个。
            if name == "p" || name == "li", current.tag == name, let parent = current.parent {
                current = parent
            }
            let node = HTMLNode(kind: .element(name), attributes: attributes, parent: current)
            current.append(node)
            if !voidTags.contains(name) && !selfClosing { current = node }
        }
        flushText(to: bytes.count)
        return root
    }

    private static func isLetter(_ byte: UInt8) -> Bool {
        (byte >= 65 && byte <= 90) || (byte >= 97 && byte <= 122)
    }

    private static func isNameChar(_ byte: UInt8) -> Bool {
        isLetter(byte) || (byte >= 48 && byte <= 57) || byte == UInt8(ascii: "-") || byte == UInt8(ascii: ":")
    }

    private static func isSpace(_ byte: UInt8) -> Bool {
        byte == 32 || byte == 9 || byte == 10 || byte == 13 || byte == 12
    }

    /// 从标签名后面开始解析属性，返回属性、标签结束后的位置、是否自闭合。
    private static func parseAttributes(_ bytes: [UInt8], from start: Int) -> ([String: String], Int, Bool) {
        var attributes: [String: String] = [:]
        var i = start
        var selfClosing = false
        while i < bytes.count {
            while i < bytes.count, isSpace(bytes[i]) { i += 1 }
            guard i < bytes.count else { break }
            if bytes[i] == UInt8(ascii: ">") { return (attributes, i + 1, selfClosing) }
            if bytes[i] == UInt8(ascii: "/") { selfClosing = true; i += 1; continue }
            let nameStart = i
            while i < bytes.count, !isSpace(bytes[i]), bytes[i] != UInt8(ascii: "="), bytes[i] != UInt8(ascii: ">"),
                  !(bytes[i] == UInt8(ascii: "/") && i + 1 < bytes.count && bytes[i + 1] == UInt8(ascii: ">")) { i += 1 }
            let name = String(decoding: bytes[nameStart..<i], as: UTF8.self).lowercased()
            if name.isEmpty { i += 1; continue }
            selfClosing = false
            while i < bytes.count, isSpace(bytes[i]) { i += 1 }
            var value = ""
            if i < bytes.count, bytes[i] == UInt8(ascii: "=") {
                i += 1
                while i < bytes.count, isSpace(bytes[i]) { i += 1 }
                if i < bytes.count, bytes[i] == UInt8(ascii: "\"") || bytes[i] == UInt8(ascii: "'") {
                    let quote = bytes[i]
                    let valueStart = i + 1
                    i = valueStart
                    while i < bytes.count, bytes[i] != quote { i += 1 }
                    value = String(decoding: bytes[valueStart..<min(i, bytes.count)], as: UTF8.self)
                    i += 1
                } else {
                    let valueStart = i
                    while i < bytes.count, !isSpace(bytes[i]), bytes[i] != UInt8(ascii: ">") { i += 1 }
                    value = String(decoding: bytes[valueStart..<i], as: UTF8.self)
                }
            }
            if attributes[name] == nil { attributes[name] = decodeEntities(value) }
        }
        return (attributes, bytes.count, selfClosing)
    }

    private static func find(_ needle: [UInt8], in bytes: [UInt8], from start: Int) -> Int? {
        guard !needle.isEmpty, start < bytes.count else { return nil }
        var i = start
        while i + needle.count <= bytes.count {
            if bytes[i] == needle[0], Array(bytes[i..<(i + needle.count)]) == needle { return i }
            i += 1
        }
        return nil
    }

    private static func findCaseInsensitive(_ needle: [UInt8], in bytes: [UInt8], from start: Int) -> Int? {
        let lower = needle.map(lowercase)
        guard !lower.isEmpty, start < bytes.count else { return nil }
        var i = start
        while i + lower.count <= bytes.count {
            if bytes[i] == lower[0] {
                var matched = true
                for k in 1..<lower.count where lowercase(bytes[i + k]) != lower[k] { matched = false; break }
                if matched { return i }
            }
            i += 1
        }
        return nil
    }

    private static func lowercase(_ byte: UInt8) -> UInt8 {
        byte >= 65 && byte <= 90 ? byte + 32 : byte
    }

    static let namedEntities: [String: String] = [
        "nbsp": "\u{00A0}", "amp": "&", "lt": "<", "gt": ">", "quot": "\"", "apos": "'",
        "times": "×", "divide": "÷", "middot": "·", "mdash": "—", "ndash": "–", "hellip": "…",
        "ldquo": "“", "rdquo": "”", "lsquo": "‘", "rsquo": "’", "deg": "°", "plusmn": "±",
        "rarr": "→", "larr": "←", "harr": "↔", "rArr": "⇒", "lArr": "⇐", "hArr": "⇔", "uarr": "↑", "darr": "↓",
        "le": "≤", "ge": "≥", "ne": "≠", "asymp": "≈", "equiv": "≡", "infin": "∞", "sup2": "²", "sup3": "³",
        "frac12": "½", "micro": "µ", "prime": "′", "permil": "‰", "ensp": "\u{2002}", "emsp": "\u{2003}",
        "thinsp": "\u{2009}", "alpha": "α", "beta": "β", "gamma": "γ", "delta": "δ", "Delta": "Δ",
        "theta": "θ", "lambda": "λ", "mu": "μ", "pi": "π", "rho": "ρ", "sigma": "σ", "omega": "ω",
        "Omega": "Ω", "phi": "φ", "copy": "©", "reg": "®", "sect": "§", "cent": "¢", "yen": "¥",
    ]

    public static func decodeEntities(_ text: String) -> String {
        guard text.contains("&") else { return text }
        var result = ""
        var index = text.startIndex
        while index < text.endIndex {
            let char = text[index]
            guard char == "&", let semicolon = text[index...].prefix(12).firstIndex(of: ";") else {
                result.append(char)
                index = text.index(after: index)
                continue
            }
            let name = String(text[text.index(after: index)..<semicolon])
            var replacement: String?
            if name.hasPrefix("#x") || name.hasPrefix("#X") {
                replacement = UInt32(name.dropFirst(2), radix: 16).flatMap(Unicode.Scalar.init).map { String($0) }
            } else if name.hasPrefix("#") {
                replacement = UInt32(name.dropFirst()).flatMap(Unicode.Scalar.init).map { String($0) }
            } else {
                replacement = namedEntities[name]
            }
            if let replacement {
                result += replacement
                index = text.index(after: semicolon)
            } else {
                result.append(char)
                index = text.index(after: index)
            }
        }
        return result
    }
}
