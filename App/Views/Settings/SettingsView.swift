import StudyKit
import SwiftData
import SwiftUI

struct SettingsView: View {
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @Environment(AppNavigation.self) private var navigation
    @Query(sort: \Provider.createdAt) private var providers: [Provider]
    @Query(sort: \ChatModel.createdAt) private var models: [ChatModel]
    @AppStorage(AppSettingsKey.defaultModelID) private var defaultModelID = ""
    @AppStorage(AppSettingsKey.customInstructions) private var customInstructions = ""
    @AppStorage(AppSettingsKey.simpleMode) private var simpleMode = false
    @AppStorage(AppSettingsKey.strongKeepAlive) private var strongKeepAlive = false
    @AppStorage(ReviewReminder.enabledKey) private var reminderEnabled = false
    @AppStorage(ReviewReminder.minutesKey) private var reminderMinutes = ReviewReminder.defaultMinutes
    @State private var permissionDenied = false
    @AppStorage(AppSettingsKey.usdToCNY) private var usdToCNY = AppSettingsKey.defaultUSDToCNY
    @State private var path = NavigationPath()
    @State private var showAddProvider = false
    /// 在"添加服务商"里选好的预设，等选择页关掉后再建服务商并打开它。
    @State private var pickedPreset: ProviderPreset?

    var body: some View {
        NavigationStack(path: $path) {
            Form {
                Section("服务商和模型") {
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

                    Button("添加服务商", systemImage: "plus") { showAddProvider = true }

                    Picker("默认模型", selection: $defaultModelID) {
                        Text("未设置").tag("")
                        ForEach(models) { model in
                            Text("\(model.provider?.name ?? "") · \(model.name)")
                                .tag(model.id.uuidString)
                        }
                    }
                }

                Section {
                    VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
                        Text("用户提示词")
                        TextEditor(text: $customInstructions)
                            .frame(minHeight: 120)
                    }
                    Toggle("简洁模式", isOn: $simpleMode)
                } header: {
                    Text("回答")
                } footer: {
                    Text("用户提示词对所有会话生效，例如：我是高二学生，讲解要循序渐进。\n简洁模式打开后，模型只用文字、公式和化学式回答，不使用坐标图等交互组件。之前已经生成的组件不受影响。")
                }

                Section {
                    Toggle("复习提醒", isOn: $reminderEnabled)
                    if reminderEnabled {
                        DatePicker("提醒时间", selection: reminderTime, displayedComponents: .hourAndMinute)
                    }
                } header: {
                    Text("复习")
                } footer: {
                    Text(permissionDenied
                         ? "通知权限被关闭了，请在系统设置 → 通知 → 格物 里打开。"
                         : "每天在这个时间提醒一次，只在有到期的错题时才提醒。")
                }
                .onChange(of: reminderEnabled) {
                    Task {
                        if reminderEnabled {
                            let granted = await ReviewReminder.requestPermission()
                            if !granted {
                                permissionDenied = true
                                reminderEnabled = false
                            }
                        }
                        ReviewReminder.reschedule(in: context)
                    }
                }
                .onChange(of: reminderMinutes) { ReviewReminder.reschedule(in: context) }

                Section {
                    LabeledContent("美元汇率") {
                        TextField("7.2", value: $usdToCNY, format: .number)
                            .keyboardType(.decimalPad)
                            .multilineTextAlignment(.trailing)
                    }
                    Toggle("强力保活", isOn: $strongKeepAlive)
                    Button("重新查看引导") {
                        navigation.onboardingAfterSettings = true
                        dismiss()
                    }
                    NavigationLink("关于") { AboutView() }
                } header: {
                    Text("其他")
                } footer: {
                    Text("""
                    费用统一按人民币显示，美元价格按这个汇率折算。内置价格是各服务商官网的标价，更新于 \(PriceTable.builtIn.updated)，不计缓存和批量折扣，所以显示的金额是估算值。

                    生成汇编要好几分钟。iOS 26 及以上默认由系统显示进度、在后台继续。打开强力保活后，生成期间会使用后台定位让 App 一直运行（旧系统也能用），状态栏会显示定位图标，比较耗电；生成结束立即关闭，位置不保存、不发送。
                    """)
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
        .sheet(isPresented: $showAddProvider, onDismiss: addPickedProvider) {
            AddProviderSheet { pickedPreset = $0 }
        }
        .onDisappear {
            try? context.save()
        }
    }

    /// 提醒时间以"从 0 点开始的分钟数"保存，DatePicker 需要一个 Date。
    private var reminderTime: Binding<Date> {
        Binding(
            get: {
                Calendar.current.date(byAdding: .minute, value: reminderMinutes, to: Calendar.current.startOfDay(for: .now)) ?? .now
            },
            set: { date in
                let parts = Calendar.current.dateComponents([.hour, .minute], from: date)
                reminderMinutes = (parts.hour ?? 20) * 60 + (parts.minute ?? 0)
            }
        )
    }

    private func addPickedProvider() {
        guard let preset = pickedPreset else { return }
        pickedPreset = nil
        let provider = ProviderSetup.makeProvider(from: preset, in: context)
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
