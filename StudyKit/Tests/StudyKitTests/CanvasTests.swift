import Foundation
import SwiftData
import Testing
@testable import StudyKit

@Suite struct CanvasSelectionTests {
    @Test func selectsIntersectionsInBothDirectionsAndAtDifferentZooms() {
        let a = UUID(), b = UUID()
        let items = [CanvasSelection.Item(id: a, center: MapPoint(x: 0, y: 0)), .init(id: b, center: MapPoint(x: 600, y: 500))]
        #expect(CanvasSelection.selected(items: items, from: MapPoint(x: 150, y: 130), to: MapPoint(x: 200, y: 200)) == [a])
        #expect(CanvasSelection.selected(items: items, from: MapPoint(x: 200, y: 200), to: MapPoint(x: -200, y: -200)) == [a])
        #expect(CanvasSelection.selected(items: items, from: MapPoint(x: .nan, y: 0), to: MapPoint(x: 0, y: 0)).isEmpty)
        #expect(CanvasSelection.world(MapPoint(x: 400, y: 300), offset: MapPoint(x: 100, y: 100), zoom: 2) == MapPoint(x: 150, y: 100))
        #expect(CanvasSelection.clampedZoom(.infinity) == 1)
        #expect(CanvasSelection.clampedZoom(0) == 0.3)
        #expect(CanvasSelection.clampedZoom(5) == 2)
    }

    @Test func promptIncludesOnlySuppliedMaterialsAndRejectsEmptyOrOversizedInputs() throws {
        let prompt = try CanvasSelection.prompt(question: "  为什么？ ", materials: [.init(title: "导数", content: "原文", location: "第 2 页")])
        #expect(prompt.contains("[画布材料1] 导数") && prompt.contains("第 2 页") && prompt.hasSuffix("为什么？"))
        #expect(throws: CanvasSelection.InputError.emptySelection) { try CanvasSelection.prompt(question: "问", materials: []) }
        #expect(throws: CanvasSelection.InputError.emptyQuestion) { try CanvasSelection.prompt(question: "\n ", materials: [.init(title: "题", content: "题")]) }
        #expect(throws: CanvasSelection.InputError.tooLarge) {
            try CanvasSelection.prompt(question: "问", materials: [.init(title: "题", content: String(repeating: "字", count: 40_001))])
        }
    }

    @Test func materialRoundTripsAttachmentsAndProvenance() throws {
        let original = StudyMaterial(title: "教材", content: "内容", location: "第 6 页",
                                     reference: .init(number: 1, kind: .card, recordID: UUID(), title: "导数"),
                                     images: [.init(data: Data([1, 2, 3]))])
        #expect(try JSONDecoder().decode(StudyMaterial.self, from: JSONEncoder().encode(original)) == original)
    }
}

@MainActor @Suite struct CanvasModelTests {
    @Test func persistsPositionDrawingStateAndCascadesOnlyOwnedContent() throws {
        let container = try ModelContainer(for: Schema(StudyAgentSchema.models), configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        let context = ModelContext(container)
        let canvas = StudyCanvas(title: "导数专题")
        context.insert(canvas)
        let item = CanvasItem(title: "曲线", content: "graph", x: -120, y: 400)
        context.insert(item); item.canvas = canvas
        item.componentStateJSON = #"{"c0":{"a":2}}"#
        item.drawingData = Data([1, 2])
        item.sourceKindRaw = "card"; item.sourceRecordID = UUID()
        let image = StoredImage(data: Data([4, 5]), contentType: "image/png")
        context.insert(image); image.canvasItem = item
        let conversation = Conversation(title: "提问")
        conversation.sourceCanvasID = canvas.id
        context.insert(conversation)
        try context.save()
        let reopened = ModelContext(container)
        let saved = try #require(reopened.fetch(FetchDescriptor<StudyCanvas>()).first)
        let savedItem = try #require(saved.sortedItems.first)
        #expect(savedItem.x == -120 && savedItem.y == 400)
        #expect(savedItem.drawingData == Data([1, 2]))
        #expect(savedItem.componentStateJSON == item.componentStateJSON)
        #expect(savedItem.sourceReference?.recordID == item.sourceRecordID)
        #expect(savedItem.images?.first?.data == Data([4, 5]))
        context.delete(canvas); try context.save()
        #expect(try context.fetchCount(FetchDescriptor<CanvasItem>()) == 0)
        #expect(try context.fetchCount(FetchDescriptor<StoredImage>()) == 0)
        #expect(try context.fetchCount(FetchDescriptor<Conversation>()) == 1)
    }
}
