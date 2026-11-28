import Foundation

/// 一份已经下载的试卷或题目目录。模型只选择正文块或真实链接，原题仍从原始 DOM 提取。
public struct PaperDocument: Sendable {
    public struct Block: Sendable, Equatable {
        public let id: String
        public let text: String
    }

    public struct Link: Sendable, Equatable {
        public let id: String
        public let title: String
        public let url: String
    }

    public let title: String
    public let url: URL
    public let blocks: [Block]
    public let links: [Link]

    private let root: HTMLNode
    /// 正文块对应的节点彼此不重叠；节点下面的图片、公式和表格结构都保留。
    private let nodeBlocks: [ObjectIdentifier: Int]
    private let descendantRanges: [ObjectIdentifier: ClosedRange<Int>]

    public init(html: String, url: URL) {
        self.url = url
        title = PageText.title(in: html)
        let root = HTMLDocument.parse(html)
        self.root = root
        let pieces = Self.partition(root)
        blocks = pieces.enumerated().map { index, nodes in
            Block(id: "B\(index + 1)", text: Self.text(in: nodes))
        }
        var nodeBlocks: [ObjectIdentifier: Int] = [:]
        for (index, nodes) in pieces.enumerated() {
            for node in nodes { nodeBlocks[ObjectIdentifier(node)] = index }
        }
        self.nodeBlocks = nodeBlocks

        var ranges: [ObjectIdentifier: ClosedRange<Int>] = [:]
        func range(of node: HTMLNode) -> ClosedRange<Int>? {
            let key = ObjectIdentifier(node)
            if let index = nodeBlocks[key] {
                ranges[key] = index...index
                return index...index
            }
            let children = node.children.compactMap(range)
            guard let first = children.first, let last = children.last else { return nil }
            let value = first.lowerBound...last.upperBound
            ranges[key] = value
            return value
        }
        _ = range(of: root)
        descendantRanges = ranges
        links = Self.links(in: root, baseURL: url)
    }

    /// 按模型选中的闭区间取原文。区间边界必须来自本页，不能用模型生成的文字代替。
    public func extract(
        startID: String, endID: String, group: Bool = false
    ) -> Swift.Result<QuestionExtractor.Result, QuestionExtractor.Failure> {
        guard let start = blocks.firstIndex(where: { $0.id == startID }),
              let end = blocks.firstIndex(where: { $0.id == endID }), start <= end
        else { return .failure(.notFound) }
        let selected = start...end
        // 长英文试卷也需要上限，不能仅按汉字数判断。题组可以保留较长的阅读材料。
        let text = blocks[selected].map(\.text).joined(separator: "\n")
        guard text.count <= (group ? 50_000 : 16_000),
              group || !Self.crossesQuestionBoundary(in: blocks[selected])
        else { return .failure(.tooLong) }

        func copy(_ node: HTMLNode, parent: HTMLNode?, whole: Bool = false) -> HTMLNode? {
            let key = ObjectIdentifier(node)
            let includeWhole = whole || nodeBlocks[key].map(selected.contains) == true
            guard includeWhole || descendantRanges[key].map({ $0.overlaps(selected) }) == true else { return nil }
            let result = HTMLNode(kind: node.kind, attributes: node.attributes, parent: parent)
            for child in node.children {
                if let copied = copy(child, parent: result, whole: includeWhole) { result.append(copied) }
            }
            return result
        }
        guard let selectedRoot = copy(root, parent: nil) else { return .failure(.notFound) }
        var renderer = MarkdownRenderer(baseURL: url)
        renderer.render(selectedRoot)
        return QuestionExtractor.renderedResult(&renderer, group: group).flatMap { result in
            result.content.isEmpty ? .failure(.notFound) : .success(result)
        }
    }

    /// 段落与表格保持完整；容器递归展开，容器中的零散文字和行内元素合为一块。
    private static func partition(_ root: HTMLNode) -> [[HTMLNode]] {
        let atomicTags: Set<String> = ["p", "table", "pre", "h1", "h2", "h3", "h4", "h5", "h6"]
        let structuralTags = MarkdownRenderer.blockTags.union(["body", "html", "table", "tr", "hr"])
        var pieces: [[HTMLNode]] = []

        func append(_ nodes: [HTMLNode]) {
            if !text(in: nodes).isEmpty { pieces.append(nodes) }
        }

        func walk(_ node: HTMLNode) {
            var inline: [HTMLNode] = []
            func flush() { append(inline); inline = [] }
            for child in node.children {
                guard let tag = child.tag else { inline.append(child); continue }
                // 高途的答案 JSON 是一整块；拆开会失去答案与原题的对应关系。
                if atomicTags.contains(tag) || child.text.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("[[") {
                    flush()
                    append([child])
                } else if structuralTags.contains(tag)
                            || child.descendants().dropFirst().contains(where: { structuralTags.contains($0.tag ?? "") }) {
                    flush()
                    walk(child)
                } else {
                    inline.append(child)
                }
            }
            flush()
        }
        walk(root)
        return pieces
    }

    /// 给模型的文字保留块边界和图片位置；实际提取使用原 DOM，不使用这段文字。
    private static func text(in nodes: [HTMLNode]) -> String {
        var output = ""
        func walk(_ node: HTMLNode) {
            if let value = node.textValue { output += MarkdownRenderer.collapse(value); return }
            guard let tag = node.tag else { return }
            if tag == "img" { output += "[图]"; return }
            let isBreak = PageText.breakTags.contains(tag)
            if isBreak { output += "\n" }
            for child in node.children { walk(child) }
            if isBreak { output += "\n" }
            if tag == "td" || tag == "th" { output += " " }
        }
        for node in nodes { walk(node) }
        return PageText.tidy(output)
    }

    private static func links(in root: HTMLNode, baseURL: URL) -> [Link] {
        var links: [Link] = []
        var seen = Set<String>()
        for node in root.descendants() where node.tag == "a" {
            guard let href = node.attributes["href"]?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !href.isEmpty, !href.hasPrefix("#"),
                  let resolved = URL(string: href, relativeTo: baseURL)?.absoluteURL,
                  ["http", "https"].contains(resolved.scheme?.lowercased() ?? ""),
                  resolved.user == nil, resolved.password == nil,
                  var components = URLComponents(url: resolved, resolvingAgainstBaseURL: true)
            else { continue }
            components.fragment = nil
            guard let address = components.url?.absoluteString,
                  let allowed = CompilationPlanner.orderedCandidates([address]).first,
                  seen.insert(allowed.absoluteString).inserted
            else { continue }
            let text = PageText.tidy(node.text)
            let title = text.isEmpty ? node.attributes["title"] ?? allowed.absoluteString : text
            links.append(Link(id: "L\(links.count + 1)", title: title, url: allowed.absoluteString))
        }
        return links
    }

    private static func crossesQuestionBoundary(in blocks: ArraySlice<Block>) -> Bool {
        let numbers: [Int] = blocks.flatMap { $0.text.split(separator: "\n") }.compactMap { line in
            let text = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard let range = text.range(of: #"^\d{1,3}\s*(?:[.．](?!\d)|、)"#, options: .regularExpression) else { return nil }
            return Int(text[range].prefix(while: \.isNumber))
        }
        guard let first = numbers.first else { return false }
        // 主题号之后回落到 1、2 的编号通常是步骤或小问，继续递增到下一道主编号才算跨题。
        return numbers.dropFirst().contains { $0 > first }
    }
}
