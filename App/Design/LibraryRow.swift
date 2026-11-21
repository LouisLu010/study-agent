import SwiftUI

/// 错题本、收藏、资料、汇编共用的列表行：标题、科目标签、一行摘要和一行小字。
struct LibraryRow<Accessory: View>: View {
    let title: String
    var subject: String?
    var summary: String?
    var meta: String?
    @ViewBuilder var accessory: Accessory

    var body: some View {
        HStack(spacing: Theme.Spacing.m) {
            VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
                Text(title)
                    .fontWeight(.medium)
                    .lineLimit(2)
                if let summary, !summary.isEmpty {
                    Text(summary)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                if subject != nil || meta != nil {
                    HStack(spacing: Theme.Spacing.s) {
                        if let subject, !subject.isEmpty {
                            SubjectTag(text: subject)
                        }
                        if let meta, !meta.isEmpty {
                            Text(meta)
                                .font(.caption)
                                .foregroundStyle(.tertiary)
                                .lineLimit(1)
                        }
                    }
                }
            }
            Spacer(minLength: 0)
            accessory
        }
        .padding(.vertical, Theme.Spacing.xs)
    }
}

extension LibraryRow where Accessory == EmptyView {
    init(title: String, subject: String? = nil, summary: String? = nil, meta: String? = nil) {
        self.init(title: title, subject: subject, summary: summary, meta: meta) { EmptyView() }
    }
}

/// 科目标签：主题色淡底的胶囊。
struct SubjectTag: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.caption2.weight(.semibold))
            .foregroundStyle(.tint)
            .padding(.horizontal, Theme.Spacing.s)
            .padding(.vertical, 2)
            .background(Color.accentColor.opacity(0.12), in: Capsule())
    }
}
