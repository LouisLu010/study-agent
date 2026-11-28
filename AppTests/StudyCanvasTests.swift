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

    @Test func snapshotsMistakeCardAndMessageAssetsWithoutDuplicateReferences() throws {
        let container = try container(), context = ModelContext(container)
        let asset = StoredImage(data: Data([1, 2]), contentType: "image/png"); context.insert(asset)
        let ref = "![](sa-asset:\(asset.id))"
        let mistake = Mistake(kind: .manual); context.insert(mistake)
        mistake.questionText = "题干"; mistake.solution = "解答 " + ref; mistake.solutionStateJSON = "state"
        asset.mistake = mistake
        let attached = MistakeImage(data: Data([3, 4]), index: 0); context.insert(attached); attached.mistake = mistake
        let material = StudyMaterialStore.record(.mistake(mistake), context: context)
        #expect(material.content.contains("解答") && material.componentStateJSON == "state" && material.images.count == 2)
        mistake.kindRaw = MistakeKind.quiz.rawValue; mistake.questionJSON = "quiz"
        #expect(StudyMaterialStore.record(.mistake(mistake), context: context).content == "quiz")
        let card = ConceptCard(title: "卡", content: ref + " " + ref); context.insert(card)
        #expect(StudyMaterialStore.record(.card(card), context: context).images.count == 1)
        let message = Message(role: .assistant, content: ref, index: 0); context.insert(message)
        #expect(StudyMaterialStore.message(message).images.count == 1)
        #expect(StudyMaterialStore.referencedImages(in: "![](sa-asset:\(UUID()))", context: context).isEmpty)
        let conversation = Conversation(title: "会话"); context.insert(conversation)
        #expect(StudyMaterialStore.record(.conversation(conversation), context: context).reference?.recordID == conversation.id)
        let emptyAsset = StoredImage(data: Data(), contentType: "image/png"); emptyAsset.data = nil
        #expect(StudyMaterialStore.image(emptyAsset) == nil)
    }

    @Test func failedQuestionLeavesNoEmptyConversationAndTooManyImagesAreRejected() throws {
        let container = try container(), context = ModelContext(container)
        let canvas = StudyCanvas(title: "专题"); context.insert(canvas)
        let item = try StudyCanvasStore.add(.init(title: "题", content: "内容"), to: canvas, at: MapPoint(x: 0, y: 0), context: context)
        let model = ChatModel(modelID: "未配置服务商"); context.insert(model)
        #expect(throws: GenerationError.self) {
            try StudyCanvasStore.ask("问题", selected: [item.id], canvas: canvas, model: model, context: context, generation: GenerationCenter())
        }
        #expect(try context.fetchCount(FetchDescriptor<Conversation>()) == 0)
        for _ in 0..<13 {
            let image = StoredImage(data: Data([1]), contentType: "image/png"); context.insert(image); image.canvasItem = item
        }
        #expect(throws: StudyMaterialStore.MaterialError.self) { try StudyCanvasStore.question("问", selected: [item.id], canvas: canvas) }
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
