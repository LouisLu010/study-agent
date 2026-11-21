import StudyKit
import SwiftData
import SwiftUI

/// 引导（见 GLOSSARY「引导」）：欢迎 → 选服务商预设 → 填 API Key → 选默认模型 → 复习提醒 → 进入新会话。
/// 本机没有服务商、也没跳过过引导时全屏出现；设置里可以重新查看。
struct OnboardingView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var context
    @Environment(AppNavigation.self) private var navigation
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @AppStorage(AppSettingsKey.onboardingSeen) private var seen = false
    @AppStorage(AppSettingsKey.defaultModelID) private var defaultModelID = ""
    @AppStorage(ReviewReminder.enabledKey) private var reminderEnabled = false

    private enum Step: Int, CaseIterable {
        case welcome, preset, apiKey, model, reminder
    }

    @State private var step = Step.welcome
    /// 往后翻还是往回翻，决定页面从哪边滑进来。
    @State private var forward = true
    @State private var preset: ProviderPreset?
    @State private var name = ""
    @State private var baseURL = ""
    @State private var apiKey = ""
    @State private var isChecking = false
    @State private var keyError: String?
    @State private var models: [RemoteModel] = []
    @State private var selectedModelID: String?
    @State private var manualModelID = ""
    @State private var modelSearch = ""
    /// 引导里建好的服务商。返回上一步重新选过时，先删掉它再建新的。
    @State private var createdProvider: Provider?
    @State private var reminderDenied = false

    var body: some View {
        VStack(spacing: 0) {
            topBar
            ZStack {
                page
                    .id(step)
                    .transition(pageTransition)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .clipped()
            bottomBar
        }
        .frame(maxWidth: 560)
        .frame(maxWidth: .infinity)
        .background(Color(.systemBackground))
        .sensoryFeedback(.selection, trigger: step)
    }

    // MARK: - 顶栏和底栏

    private var topBar: some View {
        ZStack {
            progressDots
            HStack {
                if step != .welcome {
                    Button(action: back) {
                        Image(systemName: "chevron.left")
                            .font(.headline)
                            .frame(width: 44, height: 44)
                    }
                    .accessibilityLabel("上一步")
                }
                Spacer()
                Button("跳过", action: skip)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, Theme.Spacing.l)
        .frame(height: 52)
    }

    private var progressDots: some View {
        HStack(spacing: Theme.Spacing.s) {
            ForEach(Step.allCases, id: \.self) { item in
                Capsule()
                    .fill(item == step ? Color.accentColor : Color.secondary.opacity(0.3))
                    .frame(width: item == step ? 18 : 6, height: 6)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("第 \(step.rawValue + 1) 步，共 \(Step.allCases.count) 步")
    }

    @ViewBuilder
    private var bottomBar: some View {
        if let title = primaryTitle {
            Button(action: primaryAction) {
                Text(title)
                    .font(.headline)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, Theme.Spacing.xs)
            }
            .primaryButtonStyle()
            .buttonBorderShape(.capsule)
            .controlSize(.large)
            .disabled(!canContinue)
            .padding(.horizontal, Theme.Spacing.xl)
            .padding(.top, Theme.Spacing.s)
            .padding(.bottom, Theme.Spacing.l)
        }
    }

    /// 选服务商那一页点一行就进下一步，没有底部按钮。
    private var primaryTitle: String? {
        switch step {
        case .welcome: "开始设置"
        case .preset: nil
        case .apiKey: isChecking ? "正在验证…" : "下一步"
        case .model: "下一步"
        case .reminder: "开始提问"
        }
    }

    private var canContinue: Bool {
        switch step {
        case .welcome, .preset, .reminder:
            return true
        case .apiKey:
            guard let preset, !isChecking, !trimmed(apiKey).isEmpty else { return false }
            return !preset.isCustom || !trimmed(baseURL).isEmpty
        case .model:
            return models.isEmpty ? !trimmed(manualModelID).isEmpty : selectedModelID != nil
        }
    }

    private func primaryAction() {
        switch step {
        case .welcome: go(.preset)
        case .preset: break
        case .apiKey: checkKey()
        case .model:
            saveProvider()
            go(.reminder)
        case .reminder: finish()
        }
    }

    // MARK: - 各页

    @ViewBuilder
    private var page: some View {
        switch step {
        case .welcome: welcomePage
        case .preset: presetPage
        case .apiKey: apiKeyPage
        case .model: modelPage
        case .reminder: reminderPage
        }
    }

    private var welcomePage: some View {
        ScrollView {
            VStack(spacing: Theme.Spacing.xl) {
                ActivityOrb(activity: .idle, size: 120)
                    .padding(.top, Theme.Spacing.xl)
                VStack(spacing: Theme.Spacing.s) {
                    Text("欢迎使用格物")
                        .font(.title.bold())
                    Text("为学习做的大模型聊天 App。接下来花一分钟，连上你自己的模型服务商。")
                        .foregroundStyle(.secondary)
                }
                .multilineTextAlignment(.center)
                VStack(alignment: .leading, spacing: Theme.Spacing.l) {
                    feature("function", "公式、坐标图、测验和模拟直接显示在回答里，可以动手试")
                    feature("camera", "拍题、传 PDF、手写，都能发给模型")
                    feature("arrow.counterclockwise.circle", "答错的题进错题本，按间隔自动安排复习")
                    feature("lock.shield", "用你自己的 API Key，App 直接连服务商，不经过任何服务器")
                }
            }
            .padding(.horizontal, Theme.Spacing.xl)
        }
        .scrollBounceBehavior(.basedOnSize)
    }

    private func feature(_ systemImage: String, _ text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: Theme.Spacing.m) {
            Image(systemName: systemImage)
                .foregroundStyle(.tint)
                .frame(width: 28)
            Text(text)
                .font(.callout)
        }
    }

    private var presetPage: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Spacing.l) {
                header("选择服务商", "选一家你有 API Key 的服务商。以后可以在设置里再加别的。")
                PresetList(onPick: pick)
            }
            .padding(.horizontal, Theme.Spacing.xl)
            .padding(.bottom, Theme.Spacing.xl)
        }
    }

    private var apiKeyPage: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Spacing.l) {
                ActivityOrb(activity: isChecking ? .working : .idle, size: 44)
                header(
                    preset?.isCustom == true ? "填写服务商信息" : "填写 \(preset?.name ?? "") 的 API Key",
                    "只保存在这台设备的钥匙串里。点\"下一步\"时会用它拉一次模型列表，拉到了就说明 Key 能用。"
                )
                if preset?.isCustom == true {
                    labeledField("名称") {
                        TextField("例如 通义千问", text: $name)
                    }
                    labeledField("API 地址") {
                        TextField("https://…", text: $baseURL)
                            .keyboardType(.URL)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                    }
                    Text(ProviderKind.openAICompatible.baseURLHint)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                labeledField("API Key") {
                    SecureField("粘贴 API Key", text: $apiKey)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .submitLabel(.next)
                        .onSubmit { if canContinue { checkKey() } }
                }
                if let page = preset?.apiKeyPage, let url = URL(string: page) {
                    Link("还没有 Key？去 \(preset?.name ?? "") 网站获取", destination: url)
                        .font(.callout)
                }
                if let keyError {
                    Label(keyError, systemImage: "exclamationmark.triangle")
                        .font(.callout)
                        .foregroundStyle(.red)
                }
            }
            .padding(.horizontal, Theme.Spacing.xl)
            .padding(.bottom, Theme.Spacing.xl)
        }
        .scrollDismissesKeyboard(.interactively)
    }

    private var modelPage: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.m) {
            header("选择默认模型", "新会话默认用它。这里只添加这一个，其他模型以后在设置里加。")
                .padding(.horizontal, Theme.Spacing.xl)
            if models.isEmpty {
                VStack(alignment: .leading, spacing: Theme.Spacing.m) {
                    Text("服务商没有返回模型列表。请按服务商文档填写模型 ID，大小写要一致。")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                    labeledField("模型 ID") {
                        TextField("例如 deepseek-flash", text: $manualModelID)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                    }
                }
                .padding(.horizontal, Theme.Spacing.xl)
                Spacer()
            } else {
                HStack(spacing: Theme.Spacing.s) {
                    Image(systemName: "magnifyingglass")
                        .foregroundStyle(.secondary)
                    TextField("搜索模型", text: $modelSearch)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                }
                .padding(Theme.Spacing.m)
                .cardBackground()
                .padding(.horizontal, Theme.Spacing.xl)
                ScrollView {
                    LazyVStack(spacing: Theme.Spacing.xs) {
                        ForEach(filteredModels) { model in
                            modelRow(model)
                        }
                    }
                    .padding(.horizontal, Theme.Spacing.xl)
                    .padding(.bottom, Theme.Spacing.l)
                }
                .scrollDismissesKeyboard(.interactively)
                .overlay {
                    if filteredModels.isEmpty {
                        ContentUnavailableView.search(text: modelSearch)
                    }
                }
            }
        }
    }

    private var filteredModels: [RemoteModel] {
        let query = trimmed(modelSearch)
        guard !query.isEmpty else { return models }
        return models.filter { $0.id.localizedStandardContains(query) || $0.displayName.localizedStandardContains(query) }
    }

    private func modelRow(_ model: RemoteModel) -> some View {
        let isSelected = model.id == selectedModelID
        return Button {
            selectedModelID = model.id
        } label: {
            HStack(spacing: Theme.Spacing.m) {
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .font(.title3)
                    .foregroundStyle(isSelected ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
                    .contentTransition(.symbolEffect(.replace))
                VStack(alignment: .leading, spacing: 2) {
                    Text(model.displayName.isEmpty ? model.id : model.displayName)
                        .foregroundStyle(.primary)
                    if !model.displayName.isEmpty && model.displayName != model.id {
                        Text(model.id)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer(minLength: 0)
                if model.id == preset?.recommendedModelID {
                    Text("推荐")
                        .font(.caption.bold())
                        .foregroundStyle(.tint)
                        .padding(.horizontal, Theme.Spacing.s)
                        .padding(.vertical, 2)
                        .background(Color.accentColor.opacity(0.12), in: Capsule())
                }
                if model.supportsImages == true {
                    Image(systemName: "photo")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .accessibilityLabel("支持图片")
                }
            }
            .padding(Theme.Spacing.m)
            .background(
                isSelected ? Color.accentColor.opacity(0.1) : Color.clear,
                in: RoundedRectangle(cornerRadius: Theme.cardRadius, style: .continuous)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    private var reminderPage: some View {
        ScrollView {
            VStack(spacing: Theme.Spacing.xl) {
                ActivityOrb(activity: .idle, size: 96)
                    .padding(.top, Theme.Spacing.xl)
                header(
                    "每天提醒复习",
                    "测验里答错的题会自动进错题本，按 1、3、7、14、30 天的间隔安排复习。打开提醒后，每天在设定的时间（默认 20:00）提醒一次，只在有到期的题时才提醒。",
                    centered: true
                )
                VStack(alignment: .leading, spacing: Theme.Spacing.s) {
                    Toggle("复习提醒", isOn: $reminderEnabled)
                        .padding(Theme.Spacing.m)
                        .cardBackground()
                    Text(reminderDenied
                         ? "通知权限被关闭了，可以以后在系统设置 → 通知 → 格物 里打开。"
                         : "可以先不开，以后在设置里打开或修改时间。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, Theme.Spacing.xl)
        }
        .scrollBounceBehavior(.basedOnSize)
        .onChange(of: reminderEnabled) {
            Task {
                // 打开时才请求通知权限。
                if reminderEnabled {
                    let granted = await ReviewReminder.requestPermission()
                    if !granted {
                        reminderDenied = true
                        reminderEnabled = false
                    }
                }
                ReviewReminder.reschedule(in: context)
            }
        }
    }

    private func header(_ title: String, _ message: String, centered: Bool = false) -> some View {
        VStack(alignment: centered ? .center : .leading, spacing: Theme.Spacing.s) {
            Text(title)
                .font(.title2.bold())
            Text(message)
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        .multilineTextAlignment(centered ? .center : .leading)
        .frame(maxWidth: .infinity, alignment: centered ? .center : .leading)
    }

    private func labeledField<Field: View>(_ title: String, @ViewBuilder field: () -> Field) -> some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
            Text(title)
                .font(.subheadline)
                .foregroundStyle(.secondary)
            field()
                .padding(Theme.Spacing.m)
                .cardBackground()
        }
    }

    // MARK: - 操作

    private var pageTransition: AnyTransition {
        if reduceMotion { return .opacity }
        return .asymmetric(
            insertion: .move(edge: forward ? .trailing : .leading).combined(with: .opacity),
            removal: .move(edge: forward ? .leading : .trailing).combined(with: .opacity)
        )
    }

    private func go(_ next: Step) {
        forward = next.rawValue > step.rawValue
        withAnimation(reduceMotion ? nil : .smooth(duration: 0.35)) { step = next }
    }

    private func back() {
        guard let previous = Step(rawValue: step.rawValue - 1) else { return }
        keyError = nil
        go(previous)
    }

    private func pick(_ picked: ProviderPreset) {
        if picked != preset {
            preset = picked
            name = picked.isCustom ? "" : picked.name
            baseURL = picked.isCustom ? "" : picked.baseURL
            apiKey = ""
            keyError = nil
            models = []
            selectedModelID = nil
            manualModelID = ""
            modelSearch = ""
        }
        go(.apiKey)
    }

    private var effectiveBaseURL: String {
        guard let preset else { return "" }
        return preset.isCustom ? trimmed(baseURL) : preset.baseURL
    }

    /// 用拉取模型列表来验证 API Key：拉到了就说明能用。
    private func checkKey() {
        guard let preset, canContinue else { return }
        keyError = nil
        isChecking = true
        let kind = preset.kind
        let address = effectiveBaseURL
        let key = trimmed(apiKey)
        Task {
            do {
                let fetched = try await ModelCatalog.fetch(kind: kind, baseURL: address, apiKey: key)
                models = preset.ordered(fetched)
                if selectedModelID == nil || !fetched.contains(where: { $0.id == selectedModelID }) {
                    selectedModelID = fetched.contains { $0.id == preset.recommendedModelID } ? preset.recommendedModelID : nil
                }
                isChecking = false
                go(.model)
            } catch {
                isChecking = false
                keyError = ProviderSetup.describeKeyCheckError(error)
            }
        }
    }

    /// 建服务商、存 API Key、加上选中的模型并设为默认模型。
    private func saveProvider() {
        guard let preset else { return }
        if let old = createdProvider {
            KeychainStore.deleteAPIKey(for: old.id)
            context.delete(old)
            defaultModelID = ""
        }
        let customName = trimmed(name)
        let provider = ProviderSetup.makeProvider(
            from: preset,
            name: preset.isCustom ? (customName.isEmpty ? "新服务商" : customName) : nil,
            baseURL: effectiveBaseURL,
            in: context
        )
        KeychainStore.setAPIKey(trimmed(apiKey), for: provider.id)
        let remote = models.first { $0.id == selectedModelID } ?? RemoteModel(id: trimmed(manualModelID))
        let model = ProviderSetup.addModel(remote, to: provider, in: context)
        defaultModelID = model.id.uuidString
        try? context.save()
        createdProvider = provider
    }

    private func finish() {
        seen = true
        let conversation = Conversation()
        context.insert(conversation)
        conversation.model = ModelLookup.defaultModel(in: context)
        try? context.save()
        navigation.selection = .conversation(conversation)
        dismiss()
    }

    private func skip() {
        seen = true
        dismiss()
    }

    private func trimmed(_ text: String) -> String {
        text.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
