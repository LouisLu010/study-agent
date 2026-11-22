import StudyKit
import SwiftUI

/// 服务商预设的列表，点一张卡片就选中。引导的第 2 步和设置里的"添加服务商"共用。
/// 第八版：每家是一张带官方图标的大卡片，选中的那张加主题色描边。
struct PresetList: View {
    /// 已经选中的预设（引导里返回上一步时）。
    var selectedID: String?
    let onPick: (ProviderPreset) -> Void

    var body: some View {
        VStack(spacing: Theme.Spacing.m) {
            ForEach(ProviderPreset.all) { preset in
                Button {
                    onPick(preset)
                } label: {
                    PresetRow(preset: preset, isSelected: preset.id == selectedID)
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(preset.id == selectedID ? .isSelected : [])
            }
        }
    }
}

private struct PresetRow: View {
    let preset: ProviderPreset
    let isSelected: Bool

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: Theme.cardRadius, style: .continuous)
        HStack(spacing: Theme.Spacing.m) {
            ProviderLogo(presetID: preset.id, size: 44)
            VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
                Text(preset.name)
                    .font(.headline)
                    .foregroundStyle(.primary)
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.leading)
            }
            Spacer(minLength: 0)
            Image(systemName: isSelected ? "checkmark.circle.fill" : "chevron.right")
                .font(isSelected ? .title3 : .caption.bold())
                .foregroundStyle(isSelected ? AnyShapeStyle(.tint) : AnyShapeStyle(.tertiary))
        }
        .padding(Theme.Spacing.l)
        .cardBackground()
        .overlay {
            shape.strokeBorder(isSelected ? Color.accentColor : Color.clear, lineWidth: 2)
        }
        .contentShape(shape)
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
