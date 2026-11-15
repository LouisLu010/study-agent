import StudyKit
import SwiftData
import SwiftUI

/// 切换会话使用的模型，按服务商分组。
struct ModelPickerMenu: View {
    @Binding var selection: ChatModel?
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
            HStack(spacing: 4) {
                Text(selection?.name ?? "选择模型")
                    .lineLimit(1)
                Image(systemName: "chevron.down")
                    .font(.caption)
            }
        }
    }
}
