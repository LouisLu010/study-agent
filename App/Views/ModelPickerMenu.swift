import StudyKit
import SwiftData
import SwiftUI

/// 切换会话使用的模型，按服务商分组。
struct ModelPickerMenu: View {
    enum Style {
        /// 模型名加向下的箭头。
        case plain
        /// 输入框里的一个小胶囊（第八版）：灰底、小字。
        case compact
    }

    @Binding var selection: ChatModel?
    var style: Style = .plain
    @Query(sort: \Provider.createdAt) private var providers: [Provider]

    var body: some View {
        Menu {
            ForEach(providers) { provider in
                Section(provider.name) {
                    ForEach(provider.sortedModels) { model in
                        Button {
                            selection = model
                        } label: {
                            if selection?.id == model.id {
                                Label(model.name, systemImage: "checkmark")
                            } else {
                                Text(model.name)
                            }
                        }
                    }
                }
            }
        } label: {
            switch style {
            case .plain:
                HStack(spacing: 4) {
                    Text(selection?.name ?? "选择模型")
                        .lineLimit(1)
                    Image(systemName: "chevron.down")
                        .font(.caption)
                }
            case .compact:
                HStack(spacing: 4) {
                    Text(selection?.name ?? "选择模型")
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Image(systemName: "chevron.up.chevron.down")
                        .font(.caption2.weight(.semibold))
                }
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .padding(.horizontal, Theme.Spacing.m)
                .padding(.vertical, 6)
                .background(Color(.tertiarySystemFill), in: Capsule())
            }
        }
        .accessibilityLabel("模型")
        .accessibilityValue(selection?.name ?? "未选择")
    }
}
