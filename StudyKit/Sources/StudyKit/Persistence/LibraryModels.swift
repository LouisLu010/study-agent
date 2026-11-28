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
    /// 旧版资料是否已拆为知识卡；迁移时在确认卡片保存完整后删除该原资料。
    /// 新拆卡只保存知识卡，不再建立原资料容器。
    public var isCardBased: Bool = false

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

/// 知识卡（第十版，见 GLOSSARY）：资料里的一个单位，只讲一个概念、结论或方法。
@Model
public final class ConceptCard {
    public var id: UUID = UUID()
    public var createdAt: Date = Date()
    public var updatedAt: Date = Date()
    public var title: String = ""
    /// 核心内容，Markdown，可以有公式、化学式和出处角标，不放组件。
    public var content: String = ""
    /// 一个小例子，可以没有。
    public var example: String = ""
    public var subjectRaw: String = ""
    public var topic: String = ""
    /// 出处（`[WebSource]` 的 JSON），编号和正文里的角标一致。
    public var sourcesJSON: String = ""
    /// 卡片分组 ID；从原资料拆卡时沿用 `ResearchNote.id`，原资料可已删除。
    public var noteID: UUID?
    public var sourceConversationID: UUID?
    public var modelName: String = ""
    /// 用户在关系图里拖过时记下的位置（排布坐标）。没拖过时为 nil，由排布算法决定。
    public var mapX: Double?
    public var mapY: Double?

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

    public var pinnedPosition: MapPoint? {
        get { mapX.flatMap { x in mapY.map { MapPoint(x: x, y: $0) } } }
        set { mapX = newValue?.x; mapY = newValue?.y }
    }
}

/// 关联（第十版，见 GLOSSARY 和 docs/adr/0015）：两张知识卡之间的一条连线。
/// 两头用 ID 指向知识卡，不用 SwiftData 的关系。用户删掉的模型关联不真正删除，只标 `dismissed`，
/// 以后模型再提出同一条就忽略。
@Model
public final class ConceptLink {
    public var id: UUID = UUID()
    public var createdAt: Date = Date()
    public var fromID: UUID?
    public var toID: UUID?
    /// `LinkKind` 的原始值。
    public var kindRaw: String = LinkKind.prerequisite.rawValue
    public var reason: String = ""
    /// 用户自己加的为 true，模型提出的为 false。
    public var isManual: Bool = false
    /// 用户删掉了这条模型提出的关联。
    public var dismissed: Bool = false

    public init(from: UUID, to: UUID, kind: LinkKind, reason: String = "", isManual: Bool = false) {
        fromID = from
        toID = to
        kindRaw = kind.rawValue
        self.reason = reason
        self.isManual = isManual
    }

    public var kind: LinkKind {
        get { LinkKind(rawValue: kindRaw) ?? .prerequisite }
        set { kindRaw = newValue.rawValue }
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
    /// 模型要求生成 PDF 时 App 在后台，渲染器可能不工作：记为"待生成"，回到前台再生成。
    public var pdfPending: Bool = false
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
    /// 整理时模型给的组名（按知识点或年份），印在 PDF 里。不分组时为空。
    public var groupName: String = ""
    /// 复核版本和题干、答案的摘要；正文变化后自动失效，旧题默认为待复核。
    public var reviewFingerprint: String = ""
    public var reviewRejected: Bool = false
    public var reviewNote: String = ""

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
    public var canvasItem: CanvasItem?

    public init(data: Data, contentType: String) {
        self.data = data
        self.contentType = contentType
    }
}
