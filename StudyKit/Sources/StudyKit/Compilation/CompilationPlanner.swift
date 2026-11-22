import Foundation

/// 汇编用到的网站排序、原题拼装和估价（见 docs/adr/0013）。请求和工具在 `CompilationTools` 里（ADR-0014）。
public enum CompilationPlanner {
    // MARK: - 列试卷

    /// submit_papers 交上来的试卷列表（见 `CompilationTools.parsePapers`）。
    public struct PaperList: Sendable, Equatable {
        public var title: String
        public var subject: Subject?
        public var papers: [PaperPlan]
    }

    // MARK: - 网站

    /// 已知会拒绝程序访问、或者拿不到正文的网站，不去下载。
    static let unusableHosts = ["zujuan.xkw.com", "www.zxxk.com", "51jiaoxi.com", "doc.21cnjy.com", "mp.weixin.qq.com", "xiaohongshu.com", "douyin.com", "bilibili.com"]
    /// 取图效果最好的网站排在前面。
    static let preferredHosts = ["gaotu.cn", "zujuan.21cnjy.com"]

    /// 按能不能取到原题排序，去掉已知不能用的网站；http 换成 https（App 只允许 https）。
    public static func orderedCandidates(_ urls: [String]) -> [URL] {
        var seen = Set<String>()
        let parsed = urls.compactMap { raw -> URL? in
            var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            if text.hasPrefix("http://") { text = "https://" + text.dropFirst(7) }
            guard let url = URL(string: text), let host = url.host()?.lowercased(),
                  !unusableHosts.contains(where: { host == $0 || host.hasSuffix("." + $0) }),
                  seen.insert(url.absoluteString).inserted
            else { return nil }
            return url
        }
        func rank(_ url: URL) -> Int {
            let host = url.host()?.lowercased() ?? ""
            if let index = preferredHosts.firstIndex(where: { host == $0 || host.hasSuffix("." + $0) }) {
                // 21 世纪教育网只有题目详情页能取到图。
                if preferredHosts[index] == "zujuan.21cnjy.com", !url.path().contains("/question/detail") { return 10 }
                return index
            }
            return 5
        }
        return parsed.enumerated().sorted { (rank($0.element), $0.offset) < (rank($1.element), $1.offset) }.map(\.element)
    }

    /// 网站的中文名，用于"网站解析"的标注。
    public static func siteName(for url: URL) -> String {
        let host = url.host()?.lowercased() ?? ""
        let names = [("gaotu.cn", "高途"), ("21cnjy.com", "21 世纪教育网"), ("jyeoo.com", "菁优网"), ("xkw.com", "学科网"), ("zxxk.com", "学科网"), ("51jiaoxi.com", "51 教习")]
        return names.first { host == $0.0 || host.hasSuffix("." + $0.0) }?.1 ?? host.replacingOccurrences(of: "www.", with: "")
    }

    // MARK: - 题目内容

    /// 把 `sa-image:N` 换成 App 里保存的图片 `sa-asset:<id>`；没下载到的图换成提示文字。
    public static func assemble(_ markdown: String, assets: [Int: UUID]) -> String {
        let pattern = try! NSRegularExpression(pattern: #"!\[\]\(sa-image:(\d+)( "[^"]*")?\)"#)
        let ns = markdown as NSString
        var result = ""
        var cursor = 0
        for match in pattern.matches(in: markdown, range: NSRange(location: 0, length: ns.length)) {
            result += ns.substring(with: NSRange(location: cursor, length: match.range.location - cursor))
            let index = Int(ns.substring(with: match.range(at: 1))) ?? -1
            let title = match.range(at: 2).location == NSNotFound ? "" : ns.substring(with: match.range(at: 2))
            if let id = assets[index] {
                result += "![](sa-asset:\(id.uuidString)\(title))"
            } else {
                result += "［图未能获取］"
            }
            cursor = match.range.location + match.range.length
        }
        result += ns.substring(from: cursor)
        return result
    }

    /// 例如"2025 · 北京卷 · 第 17 题"。
    public static func label(year: String, paper: String, number: String) -> String {
        var parts: [String] = []
        if !year.isEmpty { parts.append(year) }
        if !paper.isEmpty { parts.append(paper) }
        if !number.isEmpty { parts.append("第 \(number) 题") }
        return parts.joined(separator: " · ")
    }

    // MARK: - 估价

    /// 一次联网查题的大致用量，来自第七版 C0 试验（deepseek-flash 深度搜索，5 份试卷）：
    /// 输入 13 万到 68 万，约四分之三命中缓存；输出约 5 千；搜索 20 到 30 次。取中间的值。
    static let tokensPerSearchInput = 300_000
    static let cachedShare = 0.75
    static let tokensPerSearchOutput = 5_000
    static let searchesPerSearch = 25

    /// 列试卷一次加上每份试卷查一次的估算费用（人民币）。没有价格时返回 nil。
    public static func estimateCostCNY(papers: Int, price: ModelPrice?, usdToCNY: Double) -> Double? {
        guard let price else { return nil }
        let one = price.costCNY(
            inputTokens: tokensPerSearchInput,
            cachedInputTokens: Int(Double(tokensPerSearchInput) * cachedShare),
            outputTokens: tokensPerSearchOutput,
            webSearches: searchesPerSearch,
            usdToCNY: usdToCNY
        )
        return one * Double(papers)
    }

    // MARK: - 工具

    static func dateText(_ date: Date) -> String {
        let components = Calendar(identifier: .gregorian).dateComponents([.year, .month, .day], from: date)
        return "\(components.year ?? 0) 年 \(components.month ?? 0) 月 \(components.day ?? 0) 日"
    }
}
