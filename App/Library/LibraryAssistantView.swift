import StudyKit
import SwiftData
import SwiftUI

/// 父页面持有会话，收起再打开时保留对话和可撤销记录。
struct LibraryAssistantView: View {
    @Bindable var assistant: LibraryAssistant
    var scopeDescription = "全部资料"

    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @State private var text = ""
    @State private var showChanges = true
    @FocusState private var isFocused: Bool

    var body: some View {
        NavigationStack {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: Theme.Spacing.m) {
                        introduction
                        ForEach(assistant.messages) { message in
                            if !message.text.isEmpty { bubble(message) }
                        }
                        if assistant.isRunning {
                            HStack(spacing: Theme.Spacing.s) {
                                ActivityOrb(activity: .working)
                                Text(assistant.activity).font(.subheadline).foregroundStyle(.secondary)
                            }
                            .accessibilityElement(children: .combine)
                        }
                        if !assistant.changes.isEmpty { changeList }
                        if let error = assistant.errorMessage {
                            Label(error, systemImage: "exclamationmark.triangle")
                                .font(.subheadline)
                                .foregroundStyle(.red)
                        }
                        Color.clear.frame(height: 1).id("bottom")
                    }
                    .padding(Theme.Spacing.m)
                }
                .scrollDismissesKeyboard(.interactively)
                .onChange(of: assistant.messages.last?.text) { proxy.scrollTo("bottom", anchor: .bottom) }
                .onChange(of: assistant.changes.count) { proxy.scrollTo("bottom", anchor: .bottom) }
                .safeAreaInset(edge: .bottom, spacing: 0) { composer }
            }
            .background(Color(.systemGroupedBackground))
            .navigationTitle("资料助手")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") {
                        assistant.stop()
                        dismiss()
                    }
                }
            }
        }
        .accessibilityIdentifier("library-assistant-panel")
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
        .onAppear {
            if assistant.selectedModel == nil { assistant.selectedModel = ModelLookup.defaultModel(in: context) }
        }
        .onDisappear { assistant.stop() }
    }

    private var introduction: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.s) {
            Text("整理、精简或合并已有资料")
                .font(.headline)
            Text("说明要处理的范围，助手会读取资料后修改，保存的操作可以撤销。")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            if assistant.selectedModel == nil {
                Label("还没有可用模型，请在设置中添加服务商和模型后使用资料助手。", systemImage: "info.circle")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: Theme.Spacing.s) {
                    suggestion("整理分类", request: "请检查现有知识卡的科目和知识点分类，整理不准确的分类，保留原有知识内容。")
                    suggestion("精简内容", request: "请查找表述冗长的知识卡并精简，保留公式、条件、必要例子和出处。")
                    suggestion("合并重复", request: "请查找同一科目中内容重复的知识卡，将重复卡合并，保留全部必要内容、出处和关联。")
                    suggestion("拆分原文", request: "请把待整理的原资料拆成知识卡，保存成功后删除原资料，保留公式、例子和出处。")
                }
            }
        }
    }

    private func suggestion(_ title: String, request: String) -> some View {
        Button(title) {
            text = request
            isFocused = true
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
        .disabled(assistant.isRunning)
    }

    private func bubble(_ message: LibraryAssistant.Message) -> some View {
        HStack {
            if message.role == .user { Spacer(minLength: 32) }
            Text(message.text)
                .textSelection(.enabled)
                .padding(Theme.Spacing.m)
                .background(
                    message.role == .user ? Color.accentColor.opacity(0.12) : Color(.secondarySystemGroupedBackground),
                    in: RoundedRectangle(cornerRadius: Theme.fieldRadius, style: .continuous)
                )
                .accessibilityLabel(message.role == .user ? "你" : "资料助手")
                .accessibilityValue(message.text)
            if message.role == .assistant { Spacer(minLength: 20) }
        }
    }

    private var changeList: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.s) {
            DisclosureGroup("已保存 \(assistant.changes.count) 项操作", isExpanded: $showChanges) {
                VStack(alignment: .leading, spacing: Theme.Spacing.s) {
                    ForEach(assistant.changes.reversed()) { change in
                        Label(change.summary, systemImage: "checkmark.circle")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.top, Theme.Spacing.s)
            }
            Button("撤销最近操作", systemImage: "arrow.uturn.backward") {
                assistant.undoLast(context: context)
            }
            .font(.subheadline)
            .disabled(assistant.isRunning)
            .accessibilityIdentifier("library-assistant-undo")
        }
        .padding(Theme.Spacing.m)
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: Theme.fieldRadius))
    }

    private var composer: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.s) {
            TextField("例如：精简数学里关于导数的知识卡", text: $text, axis: .vertical)
                .lineLimit(1...5)
                .focused($isFocused)
                .accessibilityIdentifier("library-assistant-input")
            HStack(spacing: Theme.Spacing.s) {
                ModelPickerMenu(selection: $assistant.selectedModel, style: .compact)
                    .disabled(assistant.isRunning)
                Spacer(minLength: 0)
                if assistant.isRunning {
                    Button("停止", systemImage: "stop.fill") { assistant.stop() }
                        .labelStyle(.iconOnly)
                        .buttonStyle(.borderedProminent)
                        .buttonBorderShape(.circle)
                        .accessibilityIdentifier("library-assistant-stop")
                } else {
                    Button("发送", systemImage: "arrow.up") { send() }
                        .labelStyle(.iconOnly)
                        .buttonStyle(.borderedProminent)
                        .buttonBorderShape(.circle)
                        .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || assistant.selectedModel == nil)
                        .accessibilityIdentifier("library-assistant-send")
                }
            }
            if assistant.costCNY > 0 {
                Text("本次会话估算 \(UsageFormatting.cost(assistant.costCNY))")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(Theme.Spacing.m)
        .background(.regularMaterial)
    }

    private func send() {
        guard assistant.send(text, context: context, scopeDescription: scopeDescription) != nil else { return }
        text = ""
        isFocused = false
    }
}
