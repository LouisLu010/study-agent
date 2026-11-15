import SwiftUI

struct ComposerView: View {
    @Binding var text: String
    let isGenerating: Bool
    let canSend: Bool
    let onSend: () -> Void
    let onStop: () -> Void

    var body: some View {
        HStack(alignment: .bottom, spacing: 8) {
            TextField("发消息", text: $text, axis: .vertical)
                .lineLimit(1...6)
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 20))

            Button {
                isGenerating ? onStop() : onSend()
            } label: {
                Image(systemName: isGenerating ? "stop.circle.fill" : "arrow.up.circle.fill")
                    .font(.system(size: 34))
            }
            .disabled(!isGenerating && !canSend)
            .accessibilityLabel(isGenerating ? "停止生成" : "发送")
        }
        .padding(.horizontal)
        .padding(.vertical, 8)
    }
}
