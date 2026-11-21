import StudyKit
import SwiftUI

/// 服务商预设的列表，点一行就选中。引导的第 2 步和设置里的"添加服务商"共用。
struct PresetList: View {
    let onPick: (ProviderPreset) -> Void

    var body: some View {
        VStack(spacing: Theme.Spacing.s) {
            ForEach(ProviderPreset.all) { preset in
                Button {
                    onPick(preset)
                } label: {
                    PresetRow(preset: preset)
                }
                .buttonStyle(.plain)
            }
        }
    }
}

private struct PresetRow: View {
    let preset: ProviderPreset

    var body: some View {
        HStack(spacing: Theme.Spacing.m) {
            Image(systemName: preset.isCustom ? "ellipsis.circle" : "server.rack")
                .font(.title3)
                .foregroundStyle(.tint)
                .frame(width: 32)
            VStack(alignment: .leading, spacing: 2) {
                Text(preset.name)
                    .foregroundStyle(.primary)
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
            Image(systemName: "chevron.right")
                .font(.caption.bold())
                .foregroundStyle(.tertiary)
        }
        .padding(Theme.Spacing.m)
        .cardBackground()
        .contentShape(Rectangle())
    }

    private var detail: String {
        if preset.isCustom { return "自己填写地址，例如通义千问、Kimi、硅基流动" }
        var parts = [preset.kind.displayName + " 协议"]
        if preset.webSearchByDefault { parts.append("支持联网搜索") }
        if let model = preset.recommendedModelID { parts.append("推荐 \(model)") }
        return parts.joined(separator: " · ")
    }
}

/// 设置里的"添加服务商"：先选预设。
struct AddProviderSheet: View {
    let onPick: (ProviderPreset) -> Void

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: Theme.Spacing.m) {
                    Text("选了以后会自动填好名称、协议和地址，你只需要填 API Key。")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                    PresetList { preset in
                        onPick(preset)
                        dismiss()
                    }
                }
                .padding(Theme.Spacing.l)
            }
            .navigationTitle("添加服务商")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
            }
        }
        .presentationDetents([.medium, .large])
    }
}
