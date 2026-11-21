import Foundation
import SwiftData

// 资料和汇编。和其他模型一样遵守 CloudKit 的约束（见 docs/adr/0004），保存独立副本（见 docs/adr/0009）。

/// 资料：模型把会话里的内容和出处整理成的一份总结。
@Model
public final class ResearchNote {
    public var id: UUID = UUID()
    public var createdAt: Date = Date()
    public var updatedAt: Date = Date()
    public var title: String = ""
    /// 科目，`Subject` 的原始值。
    public var subjectRaw: String = ""
    public var topic: String = ""
    /// 正文 Markdown，可以有公式、化学式、组件和引用角标。
    public var content: String = ""
    public var componentStateJSON: String = ""
    /// 出处（`[WebSource]` 的 JSON），编号和正文里的角标一致。
    public var sourcesJSON: String = ""
    public var modelName: String = ""
    public var sourceConversationID: UUID?

    public init(title: String, content: String) {
        self.title = title
        self.content = content
    }

    public var subject: Subject? {
        get { Subject(rawValue: subjectRaw) }
        set { subjectRaw = newValue?.rawValue ?? "" }
    }

    public var sources: [WebSource] {
        get {
            guard !sourcesJSON.isEmpty else { return [] }
            return (try? JSONDecoder().decode([WebSource].self, from: Data(sourcesJSON.utf8))) ?? []
        }
        set {
            sourcesJSON = newValue.isEmpty ? "" : String(decoding: (try? JSONEncoder().encode(newValue)) ?? Data(), as: UTF8.self)
        }
    }
}

/// 汇编：从一组试卷里收集的原题，可以排版成 PDF。
@Model
public final class Compilation {
    public var id: UUID = UUID()
    public var createdAt: Date = Date()
    public var updatedAt: Date = Date()
    public var title: String = ""
    /// 用户的要求，例如"近 3 年高考有机大题"。
    public var request: String = ""
    public var subjectRaw: String = ""
    public var statusRaw: String = CompilationStatus.listing.rawValue
    /// `[PaperPlan]` 的 JSON。
    public var papersJSON: String = ""
    /// 用哪个模型（`ChatModel.id`）。
    public var modelID: UUID?
    public var modelName: String = ""
    /// PDF 里附不附答案和解析。
    public var includeAnswers: Bool = true
    @Attribute(.externalStorage) public var pdfData: Data?
    public var pdfGeneratedAt: Date?
    /// 累计的估算费用（人民币）和搜索次数。
    public var costCNY: Double = 0
    public var searches: Int = 0
    public var errorText: String?

    @Relationship(deleteRule: .cascade, inverse: \ExamQuestion.compilation)
    public var questions: [ExamQuestion]? = []

    public init(request: String) {
        self.request = request
        self.title = request
    }

    public var status: CompilationStatus {
        get { CompilationStatus(rawValue: statusRaw) ?? .paused }
        set { statusRaw = newValue.rawValue }
    }

    public var subject: Subject? {
        get { Subject(rawValue: subjectRaw) }
        set { subjectRaw = newValue?.rawValue ?? "" }
    }

    public var papers: [PaperPlan] {
        get {
            guard !papersJSON.isEmpty else { return [] }
            return (try? JSONDecoder().decode([PaperPlan].self, from: Data(papersJSON.utf8))) ?? []
        }
        set {
            papersJSON = String(decoding: (try? JSONEncoder().encode(newValue)) ?? Data(), as: UTF8.self)
        }
    }

    public var sortedQuestions: [ExamQuestion] {
        (questions ?? []).sorted { $0.index < $1.index }
    }
}

/// 汇编里的一道原题。
@Model
public final class ExamQuestion {
    public var id: UUID = UUID()
    public var createdAt: Date = Date()
    public var index: Int = 0
    public var paperTitle: String = ""
    public var paperShortTitle: String = ""
    public var year: String = ""
    /// 题号，例如"17"。
    public var number: String = ""
    /// 题目 Markdown。图片写成 `![](sa-asset:<StoredImage.id> "w=…,h=…")`。
    public var content: String = ""
    /// 答案和解析 Markdown。
    public var answer: String = ""
    public var answerKindRaw: String = ""
    /// 网站解析来自哪个网站。
    public var answerSite: String = ""
    public var statusRaw: String = ExamQuestionStatus.complete.rawValue
    /// 取到原文的网页。
    public var sourceURL: String = ""
    /// 模型给的候选网页（`[String]` 的 JSON），重新获取时用。
    public var candidateURLsJSON: String = ""
    /// 题干开头和最后一问开头的几个字，用来在网页里定位。
    public var anchor: String = ""
    public var lastAnchor: String = ""

    public var compilation: Compilation?

    @Relationship(deleteRule: .cascade, inverse: \StoredImage.question)
    public var images: [StoredImage]? = []

    public init(paperTitle: String, year: String, number: String, index: Int) {
        self.paperTitle = paperTitle
        self.year = year
        self.number = number
        self.index = index
    }

    public var status: ExamQuestionStatus {
        get { ExamQuestionStatus(rawValue: statusRaw) ?? .complete }
        set { statusRaw = newValue.rawValue }
    }

    public var answerKind: AnswerKind {
        get { AnswerKind(rawValue: answerKindRaw) ?? .none }
        set { answerKindRaw = newValue.rawValue }
    }

    public var candidateURLs: [String] {
        get { (try? JSONDecoder().decode([String].self, from: Data(candidateURLsJSON.utf8))) ?? [] }
        set { candidateURLsJSON = String(decoding: (try? JSONEncoder().encode(newValue)) ?? Data(), as: UTF8.self) }
    }

    /// 例如"2025 · 北京卷 · 第 17 题"。
    public var label: String {
        CompilationPlanner.label(year: year, paper: paperShortTitle.isEmpty ? paperTitle : paperShortTitle, number: number)
    }
}

/// 从网页上取下来的一张图片，原样保存。
@Model
public final class StoredImage {
    public var id: UUID = UUID()
    @Attribute(.externalStorage) public var data: Data?
    /// MIME 类型，例如 image/png。
    public var contentType: String = "image/png"
    public var question: ExamQuestion?
    public var mistake: Mistake?

    public init(data: Data, contentType: String) {
        self.data = data
        self.contentType = contentType
    }
}
