import Foundation
import StudyKit
import SwiftData

@MainActor
enum StudyCanvasStore {
    @discardableResult
    static func add(_ material: StudyMaterial, to canvas: StudyCanvas, at point: MapPoint, context: ModelContext) throws -> CanvasItem {
        let item = CanvasItem(title: material.title, content: material.content, x: point.x, y: point.y)
        item.sourceKindRaw = material.reference?.kind.rawValue ?? ""
        item.sourceRecordID = material.reference?.recordID
        item.sourceLocation = material.location
        item.componentStateJSON = material.componentStateJSON
        context.insert(item)
        item.canvas = canvas
        for image in material.images {
            let copy = StoredImage(data: image.data, contentType: image.contentType)
            context.insert(copy)
            copy.canvasItem = item
            if let old = image.assetID {
                item.content = item.content.replacingOccurrences(of: "sa-asset:\(old.uuidString)", with: "sa-asset:\(copy.id.uuidString)", options: .caseInsensitive)
            } else {
                item.content += "\n\n![](sa-asset:\(copy.id.uuidString))"
            }
        }
        canvas.updatedAt = .now
        do { try context.save() }
        catch { context.delete(item); throw error }
        return item
    }

    static func question(_ question: String, selected: Set<UUID>, canvas: StudyCanvas) throws -> (text: String, images: [Data]) {
        let items = canvas.sortedItems.filter { selected.contains($0.id) }
        let text = try CanvasSelection.prompt(question: question, materials: items.map {
            .init(title: $0.title, content: $0.content + ($0.componentStateJSON.isEmpty ? "" : "\n组件当前状态：\n" + $0.componentStateJSON), location: $0.sourceLocation)
        })
        let images = items.flatMap { ($0.images ?? []).compactMap(StudyMaterialStore.image) }
        guard images.count <= 12 else { throw StudyMaterialStore.MaterialError.tooManyImages }
        return (text, try StudyMaterialStore.jpegImages(images))
    }

    @discardableResult
    static func ask(_ question: String, selected: Set<UUID>, canvas: StudyCanvas, model: ChatModel,
                    context: ModelContext, generation: GenerationCenter) throws -> Conversation {
        let material = try self.question(question, selected: selected, canvas: canvas)
        let conversation = Conversation(title: canvas.title)
        conversation.titleIsAutomatic = false
        conversation.sourceCanvasID = canvas.id
        context.insert(conversation)
        conversation.model = model
        do {
            try generation.send(material.text, images: material.images, in: conversation, context: context)
            try context.save()
            return conversation
        } catch {
            generation.stop(conversation)
            context.delete(conversation)
            try? context.save()
            throw error
        }
    }
}
