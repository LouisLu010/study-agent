import StudyKit
import SwiftData
import UIKit

@MainActor
enum StudyMaterialStore {
    static func message(_ message: Message) -> StudyMaterial {
        let conversation = message.conversation
        var material = StudyMaterial(
            title: conversation?.title ?? "会话消息", content: message.contentWithStudySources,
            location: "第 \(message.index + 1) 条消息 · \(message.role == .user ? "用户" : "模型")",
            reference: conversation.map { StudyReference(number: 1, kind: .conversation, recordID: $0.id, title: $0.title) },
            componentStateJSON: message.componentStateJSON,
            images: message.imageData.map { .init(data: $0) }
        )
        if let context = message.modelContext {
            material.images += referencedImages(in: message.content, context: context)
        }
        return material
    }

    static func record(_ record: StudyRecord, context: ModelContext) -> StudyMaterial {
        var material = StudyMaterial(title: record.title, content: record.text,
                                     reference: .init(number: 1, kind: record.kind, recordID: record.id, title: record.title))
        switch record {
        case let .mistake(value):
            material.content = value.kind == .quiz ? value.questionJSON : value.questionText + "\n\n解答：\n" + value.solution
            material.componentStateJSON = value.solutionStateJSON
            material.images = value.imageData.map { .init(data: $0) }
            material.images += (value.storedImages ?? []).compactMap(image)
        case let .question(value):
            material.content = value.content + "\n\n答案与解析（\(value.answerKindRaw)）：\n" + value.answer
            material.location = value.label + "\n" + value.sourceURL
            material.images = (value.images ?? []).compactMap(image)
        case let .card(value):
            // 知识卡可能沿用资料中的图片链接；仅复制正文实际引用的图片。
            material.images = referencedImages(in: value.content + value.example, context: context)
        default: break
        }
        return material
    }

    static func image(_ image: StoredImage) -> StudyMaterial.Image? {
        image.data.map { .init(assetID: image.id, data: $0, contentType: image.contentType) }
    }

    static func referencedImages(in text: String, context: ModelContext) -> [StudyMaterial.Image] {
        let pattern = #"sa-asset:([A-Fa-f0-9-]{36})"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        var ids: Set<UUID> = []
        return regex.matches(in: text, range: NSRange(text.startIndex..., in: text)).compactMap { match in
            guard let range = Range(match.range(at: 1), in: text), let id = UUID(uuidString: String(text[range])),
                  ids.insert(id).inserted, let value = AssetSchemeHandler.image(id: id, in: context) else { return nil }
            return image(value)
        }
    }

    /// 发给模型的图片一律转为现有协议接受的 JPEG，不静默丢掉无法解码的附件。
    static func jpegImages(_ images: [StudyMaterial.Image]) throws -> [Data] {
        try images.map {
            guard let image = UIImage(data: $0.data), let jpeg = ImageCompressor.jpegData(from: image) else {
                throw MaterialError.unreadableImage
            }
            return jpeg
        }
    }

    enum MaterialError: LocalizedError {
        case unreadableImage
        case tooManyImages
        var errorDescription: String? {
            switch self {
            case .unreadableImage: "材料中有无法读取的图片，请检查后重新选择。"
            case .tooManyImages: "一次最多发送 12 张图片，请减少选择。"
            }
        }
    }
}
