import PDFKit
import SwiftUI
import UIKit

/// 打开的 PDF。选择页面后在设备上渲染成图片（见 docs/adr/0007）。
struct PDFSource: Identifiable {
    let id = UUID()
    let name: String
    let document: PDFDocument

    /// 读取用户选中的文件。文件来自其他 App 时要先获得访问权限。
    static func load(from url: URL) -> PDFSource? {
        let accessing = url.startAccessingSecurityScopedResource()
        defer { if accessing { url.stopAccessingSecurityScopedResource() } }
        guard let data = try? Data(contentsOf: url), let document = PDFDocument(data: data), document.pageCount > 0 else {
            return nil
        }
        return PDFSource(name: url.deletingPathExtension().lastPathComponent, document: document)
    }
}

enum PDFPageRenderer {
    /// 把一页渲染成白底图片，长边 2048 像素，再按普通图片压缩成 JPEG。
    static func jpegData(for page: PDFPage) -> Data? {
        let bounds = page.bounds(for: .cropBox)
        let longest = max(bounds.width, bounds.height)
        guard longest > 0 else { return nil }
        let scale = ImageCompressor.maxDimension / longest
        let size = CGSize(width: (bounds.width * scale).rounded(), height: (bounds.height * scale).rounded())
        let image = page.thumbnail(of: size, for: .cropBox)
        return ImageCompressor.jpegData(from: image)
    }
}

/// 显示 PDF 每一页的缩略图，勾选要发送的页面。
struct PDFPagePickerSheet: View {
    let source: PDFSource
    /// 还能添加多少个附件。
    let limit: Int
    let onAdd: ([Data]) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var selected: Set<Int>
    @State private var isRendering = false

    init(source: PDFSource, limit: Int, onAdd: @escaping ([Data]) -> Void) {
        self.source = source
        self.limit = limit
        self.onAdd = onAdd
        // 默认选中前面的页，最多选到上限。
        _selected = State(initialValue: Set(0..<min(source.document.pageCount, max(0, limit))))
    }

    private let columns = [GridItem(.adaptive(minimum: 104), spacing: 12)]

    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVGrid(columns: columns, spacing: 12) {
                    ForEach(0..<source.document.pageCount, id: \.self) { index in
                        pageCell(index)
                    }
                }
                .padding()
            }
            .safeAreaInset(edge: .bottom) {
                Text("已选 \(selected.count) 页，最多 \(limit) 页。每一页会作为一张图片发送。")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 10)
                    .background(.bar)
            }
            .navigationTitle(source.name)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    if isRendering {
                        ProgressView()
                    } else {
                        Button("添加", action: add)
                            .disabled(selected.isEmpty)
                    }
                }
            }
        }
    }

    private func pageCell(_ index: Int) -> some View {
        let isSelected = selected.contains(index)
        return Button {
            if isSelected {
                selected.remove(index)
            } else if selected.count < limit {
                selected.insert(index)
            }
        } label: {
            VStack(spacing: 4) {
                PDFThumbnail(page: source.document.page(at: index))
                    .overlay(
                        RoundedRectangle(cornerRadius: Theme.cardRadius, style: .continuous)
                            .stroke(isSelected ? Color.accentColor : Color(.separator), lineWidth: isSelected ? 3 : 1)
                    )
                    .overlay(alignment: .topTrailing) {
                        Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                            .font(.title3)
                            .foregroundStyle(isSelected ? Color.accentColor : Color.secondary)
                            .background(Circle().fill(.background))
                            .padding(6)
                    }
                Text("\(index + 1)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .buttonStyle(.plain)
        .disabled(!isSelected && selected.count >= limit)
    }

    private func add() {
        isRendering = true
        let pages = selected.sorted().compactMap { source.document.page(at: $0) }
        Task {
            var images: [Data] = []
            for page in pages {
                // 一页一页地渲染，渲染一页大约几十毫秒，中间让出主线程保持界面响应。
                if let data = PDFPageRenderer.jpegData(for: page) {
                    images.append(data)
                }
                await Task.yield()
            }
            onAdd(images)
            dismiss()
        }
    }
}

private struct PDFThumbnail: View {
    let page: PDFPage?
    @State private var image: UIImage?

    var body: some View {
        Group {
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFit()
            } else {
                Rectangle().fill(.quaternary)
                    .aspectRatio(0.75, contentMode: .fit)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: Theme.cardRadius, style: .continuous))
        .task {
            image = page?.thumbnail(of: CGSize(width: 240, height: 320), for: .cropBox)
        }
    }
}
