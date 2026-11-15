import StudyKit
import SwiftData
import SwiftUI

struct SettingsView: View {
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @Query(sort: \Provider.createdAt) private var providers: [Provider]
    @Query(sort: \ChatModel.createdAt) private var models: [ChatModel]
    @AppStorage(AppSettingsKey.defaultModelID) private var defaultModelID = ""
    @AppStorage(AppSettingsKey.customInstructions) private var customInstructions = ""
    @AppStorage(AppSettingsKey.simpleMode) private var simpleMode = false
    @State private var path = NavigationPath()

    var body: some View {
        NavigationStack(path: $path) {
            Form {
                Section("服务商") {
                    ForEach(providers) { provider in
                        NavigationLink(value: provider) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(provider.name.isEmpty ? "未命名服务商" : provider.name)
                                Text("\(provider.kind.displayName) · \(provider.models?.count ?? 0) 个模型")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                    .onDelete(perform: deleteProviders)

                    Button("添加服务商", systemImage: "plus", action: addProvider)
                }

                Section("默认模型") {
                    Picker("新会话使用", selection: $defaultModelID) {
                        Text("未设置").tag("")
                        ForEach(models) { model in
                            Text("\(model.provider?.name ?? "") · \(model.name)")
                                .tag(model.id.uuidString)
                        }
                    }
                }

                Section {
                    Toggle("简洁模式", isOn: $simpleMode)
                } header: {
                    Text("回答方式")
                } footer: {
                    Text("打开后模型只用文字、公式和化学式回答，不使用坐标图等交互组件。之前已经生成的组件不受影响。")
                }

                Section {
                    TextEditor(text: $customInstructions)
                        .frame(minHeight: 120)
                } header: {
                    Text("用户提示词")
                } footer: {
                    Text("对所有会话生效，例如：我是高二学生，讲解要循序渐进。")
                }
            }
            .navigationTitle("设置")
            .navigationBarTitleDisplayMode(.inline)
            .navigationDestination(for: Provider.self) { provider in
                ProviderEditView(provider: provider)
            }
            .navigationDestination(for: ChatModel.self) { model in
                ModelEditView(model: model)
            }
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") { dismiss() }
                }
            }
        }
        .onDisappear {
            try? context.save()
        }
    }

    private func addProvider() {
        let kind = ProviderKind.openAICompatible
        let provider = Provider(name: "新服务商", kind: kind, baseURL: kind.defaultBaseURL)
        context.insert(provider)
        path.append(provider)
    }

    private func deleteProviders(at offsets: IndexSet) {
        for index in offsets {
            let provider = providers[index]
            if provider.sortedModels.contains(where: { $0.id.uuidString == defaultModelID }) {
                defaultModelID = ""
            }
            KeychainStore.deleteAPIKey(for: provider.id)
            context.delete(provider)
        }
        try? context.save()
    }
}
