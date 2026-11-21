import PhotosUI
import UniformTypeIdentifiers
import SwiftUI

struct ComposerView: View {
    @Binding var text: String
    @Binding var images: [PendingImage]
    /// 当前模型是否支持图片。不支持时图片按钮显示为灰色，点按时提示原因。
    let imagesAllowed: Bool
    let isGenerating: Bool
    let canSend: Bool
    let onSend: () -> Void
    let onStop: () -> Void
    let onImagesNotAllowed: () -> Void
    /// 这个会话是否打开了"联网"。
    @Binding var webSearchEnabled: Bool
    /// 当前模型是否支持联网搜索。不支持时按钮显示为灰色，点按时提示原因。
    let webSearchAllowed: Bool
    let onWebSearchNotAllowed: () -> Void

    @State private var showPhotoPicker = false
    @State private var showCamera = false
    @State private var showHandwriting = false
    @State private var showPDFImporter = false
    @State private var pdfSource: PDFSource?
    @State private var pdfError = false
    @State private var photoItems: [PhotosPickerItem] = []

    private var remainingSlots: Int {
        max(0, ImageCompressor.maxImagesPerMessage - images.count)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if !images.isEmpty {
                pendingImages
                if images.count > ImageCompressor.costWarningThreshold {
                    Label("已添加 \(images.count) 个附件（最多 \(ImageCompressor.maxImagesPerMessage) 个），图片较多，消耗会明显增加。",
                          systemImage: "info.circle")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            HStack(alignment: .bottom, spacing: 8) {
                attachmentMenu
                webSearchButton

                TextField("发消息", text: $text, axis: .vertical)
                    .lineLimit(1...6)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                    .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 20))

                Button {
                    isGenerating ? onStop() : onSend()
                } label: {
                    Image(systemName: isGenerating ? "stop.circle.fill" : "arrow.up.circle.fill")
                        .font(.system(size: 34))
                }
                .disabled(!isGenerating && !canSend)
                .accessibilityLabel(isGenerating ? "停止生成" : "发送")
            }
        }
        .padding(.horizontal)
        .padding(.vertical, 8)
        .photosPicker(
            isPresented: $showPhotoPicker,
            selection: $photoItems,
            maxSelectionCount: max(1, remainingSlots),
            matching: .images
        )
        .onChange(of: photoItems) {
            let items = photoItems
            photoItems = []
            Task { await addPhotos(items) }
        }
        .fullScreenCover(isPresented: $showCamera) {
            CameraPicker { image in
                if let data = ImageCompressor.jpegData(from: image), let pending = PendingImage(jpeg: data) {
                    images.append(pending)
                }
            }
            .ignoresSafeArea()
        }
        .sheet(isPresented: $showHandwriting) {
            HandwritingSheet { data in
                if images.count < ImageCompressor.maxImagesPerMessage, let pending = PendingImage(jpeg: data) {
                    images.append(pending)
                }
            }
        }
        .fileImporter(isPresented: $showPDFImporter, allowedContentTypes: [.pdf]) { result in
            guard case let .success(url) = result else { return }
            if let source = PDFSource.load(from: url) {
                pdfSource = source
            } else {
                pdfError = true
            }
        }
        .sheet(item: $pdfSource) { source in
            PDFPagePickerSheet(source: source, limit: remainingSlots) { pages in
                for data in pages where images.count < ImageCompressor.maxImagesPerMessage {
                    if let pending = PendingImage(jpeg: data) {
                        images.append(pending)
                    }
                }
            }
        }
        .alert("无法打开这个 PDF", isPresented: $pdfError) {
            Button("好", role: .cancel) {}
        } message: {
            Text("文件可能已损坏或加了密码。")
        }
    }

    @ViewBuilder
    private var attachmentMenu: some View {
        if imagesAllowed {
            Menu {
                if CameraPicker.isAvailable {
                    Button("拍照", systemImage: "camera") { showCamera = true }
                }
                Button("从相册选择", systemImage: "photo.on.rectangle") { showPhotoPicker = true }
                Button("PDF 文件", systemImage: "doc.richtext") { showPDFImporter = true }
                Button("手写", systemImage: "pencil.and.scribble") { showHandwriting = true }
            } label: {
                attachmentIcon
            }
            .disabled(remainingSlots == 0)
        } else {
            Button(action: onImagesNotAllowed) {
                attachmentIcon
                    .foregroundStyle(.tertiary)
            }
        }
    }

    /// "联网"开关。打开后由模型决定这一轮要不要搜索。
    private var webSearchButton: some View {
        let isOn = webSearchEnabled && webSearchAllowed
        return Button {
            if webSearchAllowed {
                webSearchEnabled.toggle()
            } else {
                onWebSearchNotAllowed()
            }
        } label: {
            Image(systemName: "globe")
                .font(.system(size: 21))
                .foregroundStyle(isOn ? AnyShapeStyle(.white) : (webSearchAllowed ? AnyShapeStyle(.tint) : AnyShapeStyle(.tertiary)))
                .frame(width: 34, height: 34)
                .background(isOn ? AnyShapeStyle(.tint) : AnyShapeStyle(.clear), in: Circle())
                .frame(height: 40)
        }
        .accessibilityLabel("联网搜索")
        .accessibilityValue(isOn ? "已打开" : "已关闭")
    }

    private var attachmentIcon: some View {
        Image(systemName: "photo.badge.plus")
            .font(.system(size: 22))
            .frame(width: 34, height: 40)
            .accessibilityLabel("添加附件")
    }

    private var pendingImages: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(images) { image in
                    Image(uiImage: image.thumbnail)
                        .resizable()
                        .scaledToFill()
                        .frame(width: 64, height: 64)
                        .clipShape(RoundedRectangle(cornerRadius: 10))
                        .overlay(alignment: .topTrailing) {
                            Button {
                                images.removeAll { $0.id == image.id }
                            } label: {
                                Image(systemName: "xmark.circle.fill")
                                    .symbolRenderingMode(.palette)
                                    .foregroundStyle(.white, .black.opacity(0.6))
                            }
                            .offset(x: 6, y: -6)
                            .accessibilityLabel("移除图片")
                        }
                }
            }
            .padding(.top, 6)
            .padding(.trailing, 6)
        }
    }

    private func addPhotos(_ items: [PhotosPickerItem]) async {
        for item in items.prefix(remainingSlots) {
            guard let raw = try? await item.loadTransferable(type: Data.self) else { continue }
            let jpeg = await Task.detached { ImageCompressor.jpegData(from: raw) }.value
            if let jpeg, let pending = PendingImage(jpeg: jpeg), images.count < ImageCompressor.maxImagesPerMessage {
                images.append(pending)
            }
        }
    }
}
