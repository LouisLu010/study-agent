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
    @Binding var supportsWebSearch: Bool
    /// 空字符串表示自动判断。
    @Binding var webSearchDialectRaw: String
    let providerKind: ProviderKind

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
            Toggle("支持联网搜索", isOn: $supportsWebSearch)
            if supportsWebSearch && providerKind == .openAICompatible {
                Picker("搜索格式", selection: $webSearchDialectRaw) {
                    Text("自动").tag("")
                    ForEach(WebSearchDialect.allCases) { dialect in
                        Text(dialect.displayName).tag(dialect.rawValue)
                    }
                }
            }
        } footer: {
            Text(webSearchFooter)
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

extension ModelFormFields {
    fileprivate var webSearchFooter: String {
        switch providerKind {
        case .anthropic:
            "使用服务商自带的 web_search 工具。打开后，在会话输入框旁点\"联网\"即可让模型搜索。"
        case .gemini:
            "使用 Google 搜索接地。打开后，在会话输入框旁点\"联网\"即可让模型搜索。"
        case .openAICompatible:
            "使用服务商自带的搜索：DeepSeek 用 deepseek_web_search 工具，OpenAI 的 search 系列模型用 web_search_options。\"自动\"按地址和模型 ID 判断。其他服务商一般不支持。"
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
                reasoningEffortRaw: $model.reasoningEffortRaw,
                supportsWebSearch: $model.supportsWebSearch,
                webSearchDialectRaw: $model.webSearchDialectRaw,
                providerKind: model.provider?.kind ?? .openAICompatible
            )
            ModelPriceSection(model: model)
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
    @State private var supportsWebSearch = false
    @State private var webSearchDialectRaw = ""

    var body: some View {
        NavigationStack {
            Form {
                ModelFormFields(
                    modelID: $modelID,
                    displayName: $displayName,
                    supportsImages: $supportsImages,
                    reasoningEffortRaw: $reasoningEffortRaw,
                    supportsWebSearch: $supportsWebSearch,
                    webSearchDialectRaw: $webSearchDialectRaw,
                    providerKind: provider.kind
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
        model.supportsWebSearch = supportsWebSearch
        model.webSearchDialectRaw = webSearchDialectRaw
        context.insert(model)
        model.provider = provider
        try? context.save()
        if defaultModelID.isEmpty {
            defaultModelID = model.id.uuidString
        }
        dismiss()
    }
}

/// 模型的单价：显示内置的官方价格，可以手动填写覆盖（例如中转服务的价格不一样时）。
private struct ModelPriceSection: View {
    @Bindable var model: ChatModel
    @State private var inputText = ""
    @State private var outputText = ""

    var body: some View {
        Section {
            TextField("输入单价（¥ / 百万 tokens）", text: $inputText)
                .keyboardType(.decimalPad)
            TextField("输出单价（¥ / 百万 tokens）", text: $outputText)
                .keyboardType(.decimalPad)
        } header: {
            Text("价格")
        } footer: {
            Text(footer)
        }
        .onAppear {
            inputText = model.customInputPrice.map { $0.formatted(.number.grouping(.never)) } ?? ""
            outputText = model.customOutputPrice.map { $0.formatted(.number.grouping(.never)) } ?? ""
        }
        .onChange(of: inputText) { save() }
        .onChange(of: outputText) { save() }
    }

    private var footer: String {
        let rate = AppSettingsKey.usdToCNYRate
        let builtIn = PriceTable.builtIn.price(for: model.modelID)
        var text = builtIn.map { "内置价格：" + UsageFormatting.price($0, usdToCNY: rate) + "，是服务商官网的标价。" }
            ?? "内置价格表里没有这个模型，填写单价后才会显示费用。"
        text += "通过中转服务调用时价格可能不同，可以在上面手动填写，两项都填才会生效。"
        return text
    }

    private func parse(_ text: String) -> Double? {
        let value = Double(text.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: ",", with: "."))
        return value.flatMap { $0 >= 0 ? $0 : nil }
    }

    private func save() {
        model.customInputPrice = parse(inputText)
        model.customOutputPrice = parse(outputText)
    }
}
