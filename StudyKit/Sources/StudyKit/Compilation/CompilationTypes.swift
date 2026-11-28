import Foundation

/// 汇编进行到哪一步。
public enum CompilationStatus: String, Sendable {
    /// 正在请模型列出试卷。
    case listing
    /// 试卷列好了，等用户勾选确认。
    case choosing
    /// 正在逐份试卷查题。
    case collecting
    /// 试卷都查完了，正在请模型定标题、顺序和分组，然后生成 PDF（第七版）。
    case arranging
    /// 中途停下（用户停止、App 被系统暂停或关闭），可以继续。
    case paused
    case done
    /// 列试卷失败。
    case failed
}

/// 汇编里的一份试卷和它的进度，序列化后存在 `Compilation.papersJSON`。
public struct PaperPlan: Codable, Sendable, Equatable, Identifiable {
    public enum State: String, Codable, Sendable {
        case pending, done, failed
    }

    public var id: UUID
    public var title: String
    /// 题号前面显示的简称，例如"北京卷""海淀一模"。
    public var shortTitle: String
    public var year: String
    public var selected: Bool
    public var state: State
    /// 收进汇编的题数。
    public var found: Int
    /// 失败原因或说明。
    public var note: String
    /// 搜索时已经核实的整卷、目录或题目出处，后续在设备上直接下载。
    public var sourceURLs: [String]
    /// 批量收集已经核实整份试卷且没有缺题；旧版本的 done 不代表完整。
    public var collectionComplete: Bool

    public init(title: String, shortTitle: String = "", year: String, selected: Bool = true, sourceURLs: [String] = [], collectionComplete: Bool = false) {
        self.id = UUID()
        self.title = title
        self.shortTitle = shortTitle
        self.year = year
        self.selected = selected
        self.state = .pending
        self.found = 0
        self.note = ""
        self.sourceURLs = sourceURLs
        self.collectionComplete = collectionComplete
    }

    private enum CodingKeys: String, CodingKey {
        case id, title, shortTitle, year, selected, state, found, note, sourceURLs, collectionComplete
    }

    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(UUID.self, forKey: .id)
        title = try values.decode(String.self, forKey: .title)
        shortTitle = try values.decode(String.self, forKey: .shortTitle)
        year = try values.decode(String.self, forKey: .year)
        selected = try values.decode(Bool.self, forKey: .selected)
        state = try values.decode(State.self, forKey: .state)
        found = try values.decode(Int.self, forKey: .found)
        note = try values.decode(String.self, forKey: .note)
        sourceURLs = try values.decodeIfPresent([String].self, forKey: .sourceURLs) ?? []
        collectionComplete = try values.decodeIfPresent(Bool.self, forKey: .collectionComplete) ?? false
    }
}

public enum ExamQuestionStatus: String, Sendable {
    /// 原文和图都取到了。
    case complete
    /// 取到了原文，但有图没取到。
    case imagesMissing
    /// 所有出处都没取到原文。
    case notFetched
}

public enum AnswerKind: String, Sendable {
    case none = ""
    case official
    /// 题库网站附带的答案和解析。
    case site
    case ai
}
