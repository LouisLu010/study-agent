import Foundation
import StudyKit
import SwiftUI
import UIKit

/// 把整个会话导出成 Markdown 文件。组件转成可读文字，思考过程不导出，图片只标注数量。
@MainActor
enum ConversationExporter {
    static func markdown(for conversation: Conversation) -> String {
        var lines = ["# \(conversation.title)", ""]
        if let model = conversation.model {
            lines.append("> 模型：\(model.name)　导出时间：\(Date.now.formatted(date: .numeric, time: .shortened))")
            lines.append("")
        }
        for message in conversation.sortedMessages {
            switch message.role {
            case .user:
                lines.append("## 我")
                let count = message.imageData.count
                if count > 0 { lines.append("[附件：\(count) 张图片]") }
                if !message.content.isEmpty { lines.append(message.content) }
            case .assistant:
                lines.append("## \(conversation.model?.name ?? "模型")")
                if message.content.isEmpty {
                    lines.append(message.status == .failed ? "（生成失败）" : "（没有内容）")
                } else {
                    lines.append(PlainTextExporter.plainText(from: message.content))
                }
            }
            lines.append("")
        }
        return lines.joined(separator: "\n")
    }

    /// 写成临时文件，文件名用会话标题，供分享菜单使用。
    static func markdownFile(for conversation: Conversation) throws -> URL {
        let safeTitle = conversation.title
            .components(separatedBy: CharacterSet(charactersIn: "/\\:?*\"<>|\n"))
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespaces)
        let name = (safeTitle.isEmpty ? "会话" : String(safeTitle.prefix(40))) + ".md"
        let directory = FileManager.default.temporaryDirectory.appending(path: "export", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appending(path: name)
        try Data(markdown(for: conversation).utf8).write(to: url, options: .atomic)
        return url
    }
}

/// 系统分享菜单。
struct ShareSheet: UIViewControllerRepresentable {
    let items: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }

    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}

/// 要分享的内容，用来驱动 `.sheet(item:)`。
struct ShareItem: Identifiable {
    let id = UUID()
    let items: [Any]
}

/// 让外面拿到某条消息的 WebView，用来截长图。
@MainActor
final class WebViewHandle {
    weak var webView: UIView?

    /// 截下整条回答（WebView 的高度就是内容高度），加上边距和底部的 App 名称。
    func snapshot() async -> UIImage? {
        guard let webView = webView as? WKWebViewSnapshotting,
              let image = await webView.snapshotFullContent()
        else { return nil }
        return Self.decorate(image)
    }

    private static func decorate(_ content: UIImage) -> UIImage {
        let padding: CGFloat = 24
        let footerHeight: CGFloat = 36
        let size = CGSize(width: content.size.width + padding * 2, height: content.size.height + padding * 2 + footerHeight)
        let format = UIGraphicsImageRendererFormat()
        format.scale = content.scale
        format.opaque = true
        return UIGraphicsImageRenderer(size: size, format: format).image { context in
            UIColor.systemBackground.setFill()
            context.fill(CGRect(origin: .zero, size: size))
            content.draw(at: CGPoint(x: padding, y: padding))
            let footer = "Study Agent" as NSString
            let attributes: [NSAttributedString.Key: Any] = [
                .font: UIFont.preferredFont(forTextStyle: .caption1),
                .foregroundColor: UIColor.tertiaryLabel,
            ]
            let textSize = footer.size(withAttributes: attributes)
            footer.draw(
                at: CGPoint(x: size.width - padding - textSize.width, y: size.height - padding / 2 - footerHeight / 2 - textSize.height / 2),
                withAttributes: attributes
            )
        }
    }
}

/// 截图接口，由 MessageWebView 里的 WKWebView 实现。
@MainActor
protocol WKWebViewSnapshotting: AnyObject {
    func snapshotFullContent() async -> UIImage?
}
