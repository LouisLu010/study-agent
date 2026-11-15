import StudyKit
import SwiftData
import SwiftUI

struct ProviderEditView: View {
    @Bindable var provider: Provider

    @Environment(\.modelContext) private var context
    @AppStorage(AppSettingsKey.defaultModelID) private var defaultModelID = ""
    @State private var apiKey = ""
    @State private var showAddModel = false

    var body: some View {
        Form {
            Section {
                TextField("名称", text: $provider.name)
                Picker("协议", selection: $provider.kind) {
                    ForEach(ProviderKind.allCases) { kind in
                        Text(kind.displayName).tag(kind)
                    }
                }
                TextField("API 地址", text: $provider.baseURL)
                    .keyboardType(.URL)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
            } header: {
                Text("基本信息")
            } footer: {
                Text("例如 https://api.openai.com/v1 或 https://api.deepseek.com/v1")
            }

            Section {
                SecureField("sk-…", text: $apiKey)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
            } header: {
                Text("API Key")
            } footer: {
                Text("只保存在这台设备的钥匙串里。")
            }

            Section("模型") {
                ForEach(provider.sortedModels) { model in
                    NavigationLink(value: model) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(model.name)
                            if model.name != model.modelID {
                                Text(model.modelID)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }
                .onDelete(perform: deleteModels)

                Button("添加模型", systemImage: "plus") { showAddModel = true }
            }
        }
        .navigationTitle(provider.name.isEmpty ? "服务商" : provider.name)
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            apiKey = KeychainStore.apiKey(for: provider.id) ?? ""
        }
        .onChange(of: apiKey) {
            KeychainStore.setAPIKey(apiKey, for: provider.id)
        }
        .sheet(isPresented: $showAddModel) {
            AddModelSheet(provider: provider)
        }
    }

    private func deleteModels(at offsets: IndexSet) {
        let models = provider.sortedModels
        for index in offsets {
            let model = models[index]
            if model.id.uuidString == defaultModelID {
                defaultModelID = ""
            }
            context.delete(model)
        }
        try? context.save()
    }
}
