import StudyKit
import SwiftData
import SwiftUI

/// 引用按钮使用本机记录的真实标题，模型不能改变跳转目标。
struct StudyReferenceStrip: View {
    let references: [StudyReference]
    @State private var selection: StudyReference?

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: Theme.Spacing.s) {
                ForEach(references) { reference in
                    Button { selection = reference } label: {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("资料\(reference.number) · \(reference.kind.title)")
                                .font(.caption2).foregroundStyle(.secondary)
                            Text(reference.title.isEmpty ? reference.kind.title : reference.title)
                                .font(.caption.weight(.medium)).lineLimit(2)
                        }
                        .frame(width: 160, alignment: .leading)
                        .padding(10)
                        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 12))
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("打开资料\(reference.number)：\(reference.title)")
                }
            }
        }
        .sheet(item: $selection) { reference in StudyReferenceSheet(reference: reference) }
    }
}

struct StudyReferenceSheet: View {
    let reference: StudyReference
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @Environment(ToastCenter.self) private var toasts
    @State private var record: StudyRecord?
    @State private var loaded = false
    @State private var errorMessage: String?

    var body: some View {
        NavigationStack {
            Group {
                if let record, record.isAvailable(hiddenIDs: toasts.hiddenIDs) {
                    destination(record)
                } else if !loaded {
                    ProgressView()
                } else {
                    ContentUnavailableView(
                        errorMessage == nil ? "原记录已删除或不可用" : "无法读取原记录",
                        systemImage: "doc.questionmark", description: Text(errorMessage ?? reference.title)
                    )
                }
            }
            .toolbar {
                if showsCloseButton {
                    ToolbarItem(placement: .topBarTrailing) { Button("完成") { dismiss() } }
                }
            }
        }
        .task {
            do { record = try StudyRecordStore.find(kind: reference.kind, id: reference.recordID, in: context) }
            catch { errorMessage = "读取失败，请关闭后重试。" }
            loaded = true
        }
    }

    private var showsCloseButton: Bool {
        if let record, case .card = record, record.isAvailable(hiddenIDs: toasts.hiddenIDs) { return false }
        return true
    }

    @ViewBuilder
    private func destination(_ record: StudyRecord) -> some View {
        switch record {
        case let .conversation(value): ChatView(conversation: value)
        case let .mistake(value): MistakeDetailView(mistake: value)
        case let .card(value): ConceptCardPopup(startID: value.id)
        case let .compilation(value): CompilationDetailView(compilation: value)
        case let .question(value): ExamQuestionDetailView(question: value)
        }
    }
}
