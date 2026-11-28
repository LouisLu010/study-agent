import StudyKit
import SwiftData
import SwiftUI

/// 选择原记录或会话中的某条消息；使用方获得独立快照。
struct StudyMaterialPicker: View {
    let onSelect: (StudyMaterial) -> Void
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @Environment(ToastCenter.self) private var toasts
    @State private var kind: StudyRecordKind = .card
    @State private var query = ""
    @State private var records: [StudyRecord] = []
    @State private var errorText: String?

    private var visible: [StudyRecord] {
        records.filter {
            $0.isAvailable(hiddenIDs: toasts.hiddenIDs) &&
            (query.isEmpty || $0.title.localizedStandardContains(query) || $0.text.localizedStandardContains(query))
        }.sorted { $0.date > $1.date }
    }

    var body: some View {
        NavigationStack {
            List {
                Picker("内容", selection: $kind) {
                    ForEach([StudyRecordKind.card, .question, .mistake, .conversation], id: \.self) { kind in
                        Text(kind.title).tag(kind)
                    }
                }
                if let errorText { Text(errorText).foregroundStyle(.red) }
                ForEach(visible, id: \.id) { record in
                    if case let .conversation(conversation) = record {
                        NavigationLink(conversation.title) {
                            List(conversation.sortedMessages.filter { $0.status != .streaming && $0.status != .failed }) { message in
                                Button {
                                    onSelect(StudyMaterialStore.message(message)); dismiss()
                                } label: {
                                    VStack(alignment: .leading, spacing: 6) {
                                        Text("第 \(message.index + 1) 条 · \(message.role == .user ? "用户" : "模型")").font(.caption).foregroundStyle(.secondary)
                                        Text(message.content.isEmpty ? "图片消息" : message.content).lineLimit(4)
                                    }
                                }
                                .buttonStyle(.plain)
                            }
                            .navigationTitle(conversation.title)
                        }
                    } else {
                        Button {
                            onSelect(StudyMaterialStore.record(record, context: context)); dismiss()
                        } label: {
                            VStack(alignment: .leading, spacing: 6) {
                                Text(record.title).font(.headline)
                                Text(record.text).font(.caption).foregroundStyle(.secondary).lineLimit(3)
                            }
                        }
                        .buttonStyle(.plain)
                    }
                }
                if visible.isEmpty { Text("没有符合条件的内容").foregroundStyle(.secondary) }
            }
            .searchable(text: $query, prompt: "搜索标题和正文")
            .navigationTitle("选择学习内容")
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } } }
            .task(id: kind) {
                do { records = try StudyRecordStore.all(kind, in: context); errorText = nil }
                catch { records = []; errorText = "读取失败，请重试。" }
            }
        }
    }
}
