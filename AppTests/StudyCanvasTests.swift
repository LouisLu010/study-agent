import Foundation
import StudyKit
import SwiftData
import Testing
import UIKit
@testable import StudyAgent

@MainActor @Suite struct StudyCanvasTests {
    private func container() throws -> ModelContainer {
        try ModelContainer(for: Schema(StudyAgentSchema.models), configurations: ModelConfiguration(isStoredInMemoryOnly: true))
    }

    @Test func copiesQuestionAndAssetsBeforeDeletingSource() throws {
        let container = try container(), context = ModelContext(container)
        let canvas = StudyCanvas(title: "专题"), compilation = Compilation(request: "原题")
        context.insert(canvas); context.insert(compilation)
        let question = ExamQuestion(paperTitle: "数学卷", year: "2026", number: "1", index: 0)
        context.insert(question); question.compilation = compilation
        let image = StoredImage(data: Data([1, 2, 3]), contentType: "image/png")
        context.insert(image); image.question = question
        question.content = "题干 ![](sa-asset:\(image.id))"; question.answer = "答案"
        let material = StudyMaterialStore.record(.question(question), context: context)
        let item = try StudyCanvasStore.add(material, to: canvas, at: MapPoint(x: 10, y: 20), context: context)
        let imageID = image.id
        #expect(!item.content.contains(imageID.uuidString))
        #expect(item.images?.count == 1 && item.sourceRecordID == question.id)
        context.delete(compilation); try context.save()
        let saved = try #require(ModelContext(container).fetch(FetchDescriptor<CanvasItem>()).first)
        #expect(saved.content.contains("题干") && saved.content.contains("答案"))
        #expect(saved.images?.first?.data == Data([1, 2, 3]))
    }

    @Test func questionReadsOnlySelectionAndRejectsInvalidImages() throws {
        let container = try container(), context = ModelContext(container)
        let canvas = StudyCanvas(title: "专题"); context.insert(canvas)
        let a = try StudyCanvasStore.add(.init(title: "选中", content: "可发送"), to: canvas, at: MapPoint(x: 0, y: 0), context: context)
        _ = try StudyCanvasStore.add(.init(title: "未选中", content: "不可发送"), to: canvas, at: MapPoint(x: 1, y: 1), context: context)
        let result = try StudyCanvasStore.question("为什么", selected: [a.id], canvas: canvas)
        #expect(result.text.contains("可发送") && !result.text.contains("不可发送"))
        #expect(throws: CanvasSelection.InputError.emptySelection) { try StudyCanvasStore.question("问", selected: [UUID()], canvas: canvas) }
        let broken = try StudyCanvasStore.add(.init(title: "坏图", content: "", images: [.init(data: Data([0]))]), to: canvas, at: MapPoint(x: 0, y: 0), context: context)
        #expect(throws: StudyMaterialStore.MaterialError.self) { try StudyCanvasStore.question("问", selected: [broken.id], canvas: canvas) }
    }

    @Test func convertsRealImageAndPreservesMessageLocation() throws {
        let container = try container(), context = ModelContext(container)
        let conversation = Conversation(title: "会话"); context.insert(conversation)
        let message = Message(role: .assistant, content: "解答", index: 2)
        context.insert(message); message.conversation = conversation
        let material = StudyMaterialStore.message(message)
        #expect(material.location.contains("第 3 条") && material.reference?.recordID == conversation.id)
        let image = UIGraphicsImageRenderer(size: CGSize(width: 10, height: 10)).image { $0.cgContext.fill(CGRect(x: 0, y: 0, width: 10, height: 10)) }
        let png = try #require(image.pngData())
        let jpg = try #require(StudyMaterialStore.jpegImages([.init(data: png, contentType: "image/png")]).first)
        #expect(jpg.starts(with: [0xff, 0xd8]))
    }
}
