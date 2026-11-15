import StudyKit
import SwiftData
import SwiftUI

/// 模型配置的表单字段，新建和编辑共用。
struct ModelFormFields: View {
    @Binding var modelID: String
    @Binding var displayName: String
    @Binding var supportsImages: Bool

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
    }
}

struct ModelEditView: View {
    @Bindable var model: ChatModel

    var body: some View {
        Form {
            ModelFormFields(
                modelID: $model.modelID,
                displayName: $model.displayName,
                supportsImages: $model.supportsImages
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

    var body: some View {
        NavigationStack {
            Form {
                ModelFormFields(modelID: $modelID, displayName: $displayName, supportsImages: $supportsImages)
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
        context.insert(model)
        model.provider = provider
        try? context.save()
        if defaultModelID.isEmpty {
            defaultModelID = model.id.uuidString
        }
        dismiss()
    }
}
