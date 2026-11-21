import Foundation

/// 错题、收藏、资料和汇编的科目。
public enum Subject: String, CaseIterable, Identifiable, Sendable {
    case math = "数学"
    case physics = "物理"
    case chemistry = "化学"
    case biology = "生物"
    case chinese = "语文"
    case english = "英语"
    case other = "其他"

    public var id: String { rawValue }

    /// 把模型写的科目归到固定的几个里，归不上算"其他"；空字符串返回 nil（表示还没分类）。
    public static func normalize(_ text: String) -> Subject? {
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return nil }
        if let match = allCases.first(where: { value.contains($0.rawValue) }) { return match }
        switch value.lowercased() {
        case "math", "mathematics": return .math
        case "physics": return .physics
        case "chemistry": return .chemistry
        case "biology": return .biology
        case "chinese": return .chinese
        case "english": return .english
        default: return .other
        }
    }
}
