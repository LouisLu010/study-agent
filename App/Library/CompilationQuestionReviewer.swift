import CryptoKit
import Foundation
import StudyKit
import SwiftData

/// 批量复核原文块；保存后的题只在内容变化或复核协议升级时重新请求模型。
@MainActor
final class CompilationQuestionReviewer {
    typealias Reviewed = CompilationQuestionReview.Reviewed

    enum ReviewError: LocalizedError, Equatable {
        case invalidCandidates
        case contentChanged

        var errorDescription: String? {
            switch self {
            case .invalidCandidates: "待复核题目的 ID 必须非空且不能重复。"
            case .contentChanged: "复核期间题目已被修改、移动或删除，请重新尝试。"
            }
        }
    }

    private struct PaperKey: Hashable {
        let title: String
        let year: String
    }

    private struct Snapshot {
        let question: ExamQuestion
        let fingerprint: String
        let compilationID: UUID?
        let paper: PaperKey
        let number: String
    }

    private static let reviewVersion = "1"
    private let session: CompilationBatchSession
    private let context: ModelContext

    init(session: CompilationBatchSession, context: ModelContext) {
        self.session = session
        self.context = context
    }

    /// 每批最多 8 题、约 24k 字符；超长题独占一批，绝不截断题干和原图。
    func review(_ candidates: [CompilationQuestionReview.Candidate], paper: PaperPlan) async throws -> [Reviewed] {
        try Task.checkCancellation()
        guard candidates.allSatisfy({ !$0.id.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }),
              Set(candidates.map(\.id)).count == candidates.count
        else { throw ReviewError.invalidCandidates }
        var reviewed: [Reviewed] = []
        for batch in Self.batches(candidates) {
            try Task.checkCancellation()
            session.log(.step, "复核原题：\(paper.shortTitle.isEmpty ? paper.title : paper.shortTitle)，共 \(batch.count) 题")
            let reply = try await session.reply(to: CompilationQuestionReview.request(
                model: session.model.modelID, paper: paper, request: session.compilation.request, candidates: batch
            ))
            reviewed += try CompilationQuestionReview.parse(reply, candidates: batch)
        }
        return reviewed
    }

    /// 旧题和复用题共用此入口；失败保留原文，成功后才记录最终内容的指纹。
    func ensureReviewed(_ questions: [ExamQuestion]) async throws {
        try Task.checkCancellation()
        var seen = Set<UUID>()
        var order: [PaperKey] = []
        var groups: [PaperKey: [Snapshot]] = [:]
        for question in questions where seen.insert(question.id).inserted && !Self.hasCurrentReview(question) {
            guard question.modelContext === context, !question.isDeleted else { throw ReviewError.contentChanged }
            let key = PaperKey(title: question.paperTitle, year: question.year)
            if groups[key] == nil { order.append(key) }
            groups[key, default: []].append(Snapshot(
                question: question, fingerprint: Self.fingerprint(question), compilationID: question.compilation?.id,
                paper: key, number: question.number
            ))
        }
        for key in order {
            guard let snapshots = groups[key] else { continue }
            guard snapshots.allSatisfy(isCurrent) else { throw ReviewError.contentChanged }
            let paper = session.compilation.papers.first { $0.title == key.title && $0.year == key.year }
                ?? PaperPlan(title: key.title, shortTitle: snapshots.first?.question.paperShortTitle ?? "", year: key.year)
            let candidates = snapshots.map { snapshot in
                CompilationQuestionReview.Candidate(
                    id: snapshot.question.id.uuidString, number: snapshot.number,
                    content: snapshot.question.content, answer: snapshot.question.answer
                )
            }
            let reviewed = try await review(candidates, paper: paper)
            try Task.checkCancellation()
            // 模型返回前用户可能编辑或删除题目。整组检查通过后才落库，避免覆盖新内容。
            guard snapshots.allSatisfy(isCurrent) else { throw ReviewError.contentChanged }
            for (snapshot, result) in zip(snapshots, reviewed) {
                apply(result, to: snapshot.question)
            }
            try context.save()
        }
    }

    static func hasCurrentReview(_ question: ExamQuestion) -> Bool {
        !question.reviewFingerprint.isEmpty && question.reviewFingerprint == fingerprint(question)
    }

    static func isReviewed(_ question: ExamQuestion) -> Bool {
        hasCurrentReview(question) && !question.reviewRejected
    }

    static func markReviewed(_ question: ExamQuestion) {
        question.reviewFingerprint = fingerprint(question)
        question.reviewRejected = false
        question.reviewNote = ""
    }

    private func isCurrent(_ snapshot: Snapshot) -> Bool {
        let question = snapshot.question
        return question.modelContext === context && !question.isDeleted
            && question.compilation?.id == snapshot.compilationID
            && question.paperTitle == snapshot.paper.title && question.year == snapshot.paper.year
            && question.number == snapshot.number && Self.fingerprint(question) == snapshot.fingerprint
    }

    private func apply(_ result: Reviewed, to question: ExamQuestion) {
        if result.isQuestion {
            question.content = result.content
            question.answer = result.answer
            if question.answer.isEmpty {
                question.answerKind = .none
                question.answerSite = ""
            } else if question.answerKind == .none {
                question.answerKind = .site
                question.answerSite = URL(string: question.sourceURL).map(CompilationPlanner.siteName(for:)) ?? ""
            }
            let referenced = Set(CompilationCenter.imageIDs(in: question.content + "\n" + question.answer))
            let images = question.images ?? []
            for image in images where !referenced.contains(image.id) { context.delete(image) }
            question.images = images.filter { referenced.contains($0.id) }
            Self.markReviewed(question)
        } else {
            // 拒绝不删用户旧题；保存这次判定，下次导出或继续收集时可以直接提示补取。
            question.reviewFingerprint = Self.fingerprint(question)
            question.reviewRejected = true
            question.reviewNote = result.note.isEmpty ? "没有可核实的原题，请编辑或重新获取。" : result.note
            if let compilation = question.compilation {
                if compilation.status == .done { compilation.status = .paused }
                var papers = compilation.papers
                for index in papers.indices where papers[index].title == question.paperTitle && papers[index].year == question.year {
                    papers[index].collectionComplete = false
                    papers[index].state = .failed
                    papers[index].note = "第 \(question.number) 题未通过复核：\(question.reviewNote)"
                }
                compilation.papers = papers
            }
            session.log(.warning, "\(question.label)：\(question.reviewNote)")
        }
        question.compilation?.pdfData = nil
        question.compilation?.pdfGeneratedAt = nil
        question.compilation?.pdfPending = false
        question.compilation?.updatedAt = .now
    }

    private static func fingerprint(_ question: ExamQuestion) -> String {
        // 长度前缀区分题干与答案，避免不同字段组合得到相同输入。
        let source = [reviewVersion, question.content, question.answer].map { "\($0.utf8.count):\($0)" }.joined()
        return SHA256.hash(data: Data(source.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    static func batches(_ candidates: [CompilationQuestionReview.Candidate]) -> [[CompilationQuestionReview.Candidate]] {
        var result: [[CompilationQuestionReview.Candidate]] = []
        var current: [CompilationQuestionReview.Candidate] = []
        var size = 0
        for candidate in candidates {
            let added = candidate.id.count + candidate.number.count + 40
                + candidate.blocks.reduce(0) { $0 + $1.text.count + $1.id.count + $1.origin.rawValue.count + 40 }
            if !current.isEmpty, current.count == 8 || size + added > 24_000 {
                result.append(current)
                current = []
                size = 0
            }
            current.append(candidate)
            size += added
        }
        if !current.isEmpty { result.append(current) }
        return result
    }
}
