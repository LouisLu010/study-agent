import Foundation
import StudyKit
import SwiftData

/// 跨汇编复用已经核实的题目和来源；复制原文与图片，不共享会被级联删除的模型。
@MainActor
enum CompilationReuse {
    struct Candidate {
        let compilation: Compilation
        let paper: PaperPlan
        let questions: [ExamQuestion]
        let sourceURLs: [String]
        let canReuseAll: Bool
    }

    static func candidates(
        for paper: PaperPlan, in compilation: Compilation, context: ModelContext
    ) throws -> [Candidate] {
        guard compilation.subject != nil else { return [] }
        let others = try context.fetch(FetchDescriptor<Compilation>(sortBy: [SortDescriptor(\.updatedAt, order: .reverse)]))
        return others.compactMap { source in
            guard source.id != compilation.id, source.subjectRaw == compilation.subjectRaw,
                  let matched = source.papers.first(where: { $0.title == paper.title && $0.year == paper.year })
            else { return nil }
            let all = source.sortedQuestions.filter { $0.paperTitle == paper.title && $0.year == paper.year }
            let complete = all.filter(isComplete)
            let urls = sourceURLs(matched.sourceURLs + all.flatMap { [$0.sourceURL] + $0.candidateURLs })
            guard !complete.isEmpty || !urls.isEmpty else { return nil }
            return Candidate(
                compilation: source, paper: matched, questions: complete, sourceURLs: urls,
                canReuseAll: source.request == compilation.request && matched.collectionComplete
                    && !all.isEmpty && matched.found == all.count && complete.count == all.count
            )
        }
    }

    @discardableResult
    static func copy(
        _ candidate: Candidate, into compilation: Compilation, paper: PaperPlan, context: ModelContext
    ) -> [ExamQuestion] {
        copyQuestions(candidate.questions, into: compilation, paper: paper, context: context)
    }

    /// 也用于模型从其他要求的汇编里选中若干道题。调用者负责保存整个收集阶段的进度。
    @discardableResult
    static func copyQuestions(
        _ questions: [ExamQuestion], into compilation: Compilation, paper: PaperPlan, context: ModelContext
    ) -> [ExamQuestion] {
        guard compilation.subject != nil else { return [] }
        var copied: [ExamQuestion] = []
        var nextIndex = (compilation.questions?.map(\.index).max() ?? -1) + 1
        for source in questions {
            guard let owner = source.compilation, owner.id != compilation.id,
                  owner.subjectRaw == compilation.subjectRaw,
                  source.paperTitle == paper.title, source.year == paper.year, isComplete(source)
            else { continue }
            let existing = (compilation.questions ?? []).first {
                $0.paperTitle == paper.title && $0.year == paper.year && CompilationTools.sameNumber($0.number, source.number)
            }
            if let existing, isComplete(existing) { continue }
            let question: ExamQuestion
            if let existing {
                question = existing
                for image in existing.images ?? [] { context.delete(image) }
                question.images = []
            } else {
                question = ExamQuestion(paperTitle: paper.title, year: paper.year, number: source.number, index: nextIndex)
                nextIndex += 1
                context.insert(question)
                question.compilation = compilation
            }
            var ids: [UUID: UUID] = [:]
            for image in source.images ?? [] {
                guard let data = image.data else { continue }
                let copy = StoredImage(data: data, contentType: image.contentType)
                context.insert(copy)
                copy.question = question
                ids[image.id] = copy.id
            }
            question.paperShortTitle = paper.shortTitle
            question.content = rewriteAssets(in: source.content, ids: ids)
            question.answer = rewriteAssets(in: source.answer, ids: ids)
            question.answerKind = source.answerKind
            question.answerSite = source.answerSite
            question.status = .complete
            question.sourceURL = source.sourceURL
            question.candidateURLs = source.candidateURLs
            question.anchor = source.anchor
            question.lastAnchor = source.lastAnchor
            question.groupName = source.groupName
            // 图片复制会改写 UUID，摘要必须基于复制后的原文重新计算。
            if CompilationQuestionReviewer.isReviewed(source) {
                CompilationQuestionReviewer.markReviewed(question)
            } else {
                question.reviewFingerprint = ""
                question.reviewRejected = false
                question.reviewNote = ""
            }
            copied.append(question)
        }
        if !copied.isEmpty {
            compilation.pdfData = nil
            compilation.pdfGeneratedAt = nil
            compilation.pdfPending = false
            compilation.updatedAt = .now
        }
        return copied
    }

    /// 状态为完整还不够：题干和它引用的图片必须实际存在。
    private static func isComplete(_ question: ExamQuestion) -> Bool {
        guard question.statusRaw == ExamQuestionStatus.complete.rawValue,
              !(CompilationQuestionReviewer.hasCurrentReview(question) && question.reviewRejected),
              !question.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !CompilationTools.normalizeNumber(question.number).isEmpty
        else { return false }
        let images = question.images ?? []
        let available = Set(images.filter { $0.data?.isEmpty == false }.map(\.id))
        let referenced = Set(CompilationCenter.imageIDs(in: question.content + "\n" + question.answer))
        return referenced.isSubset(of: available)
    }

    private static func sourceURLs(_ values: [String]) -> [String] {
        var seen = Set<String>()
        return values.compactMap { value in
            guard let url = URL(string: value), let normalized = try? CompilationSourceStore.normalizedURL(url),
                  seen.insert(normalized.absoluteString).inserted
            else { return nil }
            return normalized.absoluteString
        }
    }

    private static func rewriteAssets(in markdown: String, ids: [UUID: UUID]) -> String {
        var result = markdown
        for (old, new) in ids {
            result = result.replacingOccurrences(of: "sa-asset:" + old.uuidString, with: "sa-asset:" + new.uuidString, options: .caseInsensitive)
        }
        return result
    }
}
