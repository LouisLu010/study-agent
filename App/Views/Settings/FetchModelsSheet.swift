import StudyKit
import SwiftData
import SwiftUI

/// 从服务商接口获取模型列表，勾选后批量添加。
struct FetchModelsSheet: View {
    let provider: Provider

    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @AppStorage(AppSettingsKey.defaultModelID) private var defaultModelID = ""

    private enum LoadState {
        case loading
        case failed(String)
        case loaded([RemoteModel])
    }

    @State private var state = LoadState.loading
    @State private var selection = Set<String>()
    @State private var searchText = ""

    /// 这个服务商下已经添加过的模型 ID。
    private var existingIDs: Set<String> {
        Set(provider.sortedModels.map(\.modelID))
    }

    var body: some View {
        NavigationStack {
            content
                .navigationTitle("获取模型")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("取消") { dismiss() }
                    }
                    ToolbarItem(placement: .confirmationAction) {
                        Button(selection.isEmpty ? "添加" : "添加 \(selection.count) 个", action: addSelected)
                            .disabled(selection.isEmpty)
                    }
                }
        }
        .task { await load() }
    }

    @ViewBuilder
    private var content: some View {
        switch state {
        case .loading:
            ProgressView("正在获取模型列表…")
                .frame(maxWidth: .infinity, maxHeight: .infinity)

        case let .failed(message):
            ContentUnavailableView {
                Label("获取失败", systemImage: "exclamationmark.triangle")
            } description: {
                Text(message)
            } actions: {
                Button("重试") { Task { await load() } }
                    .buttonStyle(.bordered)
            }

        case let .loaded(models):
            let filtered = filter(models)
            List {
                Section {
                    ForEach(filtered) { model in
                        row(for: model)
                    }
                } footer: {
                    Text("共 \(models.count) 个模型。是否支持图片由服务商的信息推断，添加后可以在模型设置里修改。")
                }
            }
            .searchable(text: $searchText, placement: .navigationBarDrawer(displayMode: .always), prompt: "搜索模型 ID 或名称")
            .overlay {
                if models.isEmpty {
                    ContentUnavailableView("服务商没有返回任何模型", systemImage: "tray")
                } else if filtered.isEmpty {
                    ContentUnavailableView.search(text: searchText)
                }
            }
        }
    }

    private func row(for model: RemoteModel) -> some View {
        let isAdded = existingIDs.contains(model.id)
        let isSelected = selection.contains(model.id)
        return Button {
            if isSelected {
                selection.remove(model.id)
            } else {
                selection.insert(model.id)
            }
        } label: {
            HStack(spacing: 12) {
                Image(systemName: isAdded ? "checkmark.circle" : (isSelected ? "checkmark.circle.fill" : "circle"))
                    .font(.title3)
                    .foregroundStyle(isAdded ? Color.secondary : (isSelected ? Color.accentColor : Color.secondary))

                VStack(alignment: .leading, spacing: 2) {
                    Text(model.displayName.isEmpty ? model.id : model.displayName)
                        .foregroundStyle(isAdded ? .secondary : .primary)
                    if !model.displayName.isEmpty && model.displayName != model.id {
                        Text(model.id)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                Spacer()

                if isAdded {
                    Text("已添加")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else if model.supportsImages == true {
                    Image(systemName: "photo")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .accessibilityLabel("支持图片")
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(isAdded)
    }

    private func filter(_ models: [RemoteModel]) -> [RemoteModel] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return models }
        return models.filter {
            $0.id.localizedStandardContains(query) || $0.displayName.localizedStandardContains(query)
        }
    }

    private func load() async {
        state = .loading
        do {
            let models = try await ModelCatalog.fetch(
                kind: provider.kind,
                baseURL: provider.baseURL,
                apiKey: KeychainStore.apiKey(for: provider.id) ?? ""
            )
            state = .loaded(models)
        } catch {
            state = .failed(ChatErrorDescription.describe(error))
        }
    }

    private func addSelected() {
        guard case let .loaded(models) = state else { return }
        let existing = existingIDs
        // 按服务商列表里的顺序添加。
        for remote in models where selection.contains(remote.id) && !existing.contains(remote.id) {
            let displayName = remote.displayName == remote.id ? "" : remote.displayName
            let model = ChatModel(
                modelID: remote.id,
                displayName: displayName,
                supportsImages: remote.supportsImages ?? false
            )
            context.insert(model)
            model.provider = provider
            if defaultModelID.isEmpty {
                defaultModelID = model.id.uuidString
            }
        }
        try? context.save()
        dismiss()
    }
}
