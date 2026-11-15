import StudyKit
import SwiftUI
import UIKit

/// M1 只显示纯文本，M2 换成 WebView 渲染。
struct MessageRow: View {
    let message: Message

    var body: some View {
        switch message.role {
        case .user: userBubble
        case .assistant: assistantBody
        }
    }

    private var userBubble: some View {
        HStack {
            Spacer(minLength: 48)
            Text(message.content)
                .textSelection(.enabled)
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .background(Color.accentColor.opacity(0.15), in: RoundedRectangle(cornerRadius: 18))
                .contextMenu { copyButton }
        }
    }

    private var assistantBody: some View {
        VStack(alignment: .leading, spacing: 8) {
            if message.content.isEmpty && message.status == .streaming {
                ProgressView()
            } else if !message.content.isEmpty {
                Text(message.content)
                    .textSelection(.enabled)
                    .contextMenu { copyButton }
            }

            switch message.status {
            case .failed:
                Label(message.errorText ?? "生成失败。", systemImage: "exclamationmark.triangle")
                    .font(.callout)
                    .foregroundStyle(.red)
            case .stopped:
                Text("已停止生成")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            case .complete, .streaming:
                EmptyView()
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var copyButton: some View {
        Button("复制", systemImage: "doc.on.doc") {
            UIPasteboard.general.string = message.content
        }
    }
}
