import StudyKit
import SwiftData
import SwiftUI

/// 模型配置的表单字段，新建和编辑共用。
struct ModelFormFields: View {
    @Binding var modelID: String
    @Binding var displayName: String
    @Binding var supportsImages: Bool
    /// 空字符串表示使用服务商的默认值。
    @Binding var reasoningEffortRaw: String

    var body: some View {
        Section {
            TextField("模型 ID，例如 gpt-4o", text: $modelID)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
            TextField("显示名称（可选）", text: $displayName)
        } footer: {
            Text("模型 ID 要和服务商文档里写的完全一致。")
        }

        Section {
            Toggle("支持图片输入", isOn: $supportsImages)
        }

        Section {
            Picker("思考强度", selection: $reasoningEffortRaw) {
                Text("默认").tag("")
                ForEach(ReasoningEffort.allCases) { effort in
                    Text(effort.displayName).tag(effort.rawValue)
                }
            }
        } footer: {
            Text("只对推理模型有效。不支持这个参数的模型可能会报错，这时改回\"默认\"即可。Claude 只有设置了思考强度才会返回思考过程。")
        }
    }
}

struct ModelEditView: View {
    @Bindable var model: ChatModel

    var body: some View {
        Form {
            ModelFormFields(
                modelID: $model.modelID,
                displayName: $model.displayName,
                supportsImages: $model.supportsImages,
                reasoningEffortRaw: $model.reasoningEffortRaw
            )
        }
        .navigationTitle(model.name.isEmpty ? "模型" : model.name)
        .navigationBarTitleDisplayMode(.inline)
    }
}

struct AddModelSheet: View {
    let provider: Provider

    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @AppStorage(AppSettingsKey.defaultModelID) private var defaultModelID = ""
    @State private var modelID = ""
    @State private var displayName = ""
    @State private var supportsImages = false
    @State private var reasoningEffortRaw = ""

    var body: some View {
        NavigationStack {
            Form {
                ModelFormFields(
                    modelID: $modelID,
                    displayName: $displayName,
                    supportsImages: $supportsImages,
                    reasoningEffortRaw: $reasoningEffortRaw
                )
            }
            .navigationTitle("添加模型")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("添加", action: add)
                        .disabled(trimmedModelID.isEmpty)
                }
            }
        }
    }

    private var trimmedModelID: String {
        modelID.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func add() {
        let model = ChatModel(
            modelID: trimmedModelID,
            displayName: displayName.trimmingCharacters(in: .whitespacesAndNewlines),
            supportsImages: supportsImages
        )
        model.reasoningEffortRaw = reasoningEffortRaw
        context.insert(model)
        model.provider = provider
        try? context.save()
        if defaultModelID.isEmpty {
            defaultModelID = model.id.uuidString
        }
        dismiss()
    }
}
