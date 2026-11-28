import PhotosUI
import StudyKit
import UniformTypeIdentifiers
import SwiftUI

/// 输入框放在哪里。
enum ComposerPlacement {
    /// 聊天页底部，浮在消息上面（玻璃效果）。
    case bottomBar
    /// "今天"页里的一张卡片。
    case inline
}

/// 输入框（第八版）：浮起的大圆角卡片，上面一行输入文字，下面一行放附件、联网开关和模型名，右边是实心圆形发送按钮。
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
    /// 下一条消息用的模型，显示在输入框里，点开可以换。
    @Binding var model: ChatModel?
    var placement: ComposerPlacement = .bottomBar
    /// 打开页面时自动弹出键盘（第九版：新会话直接打字）。
    var autoFocus = false
    /// 打开页面时直接弹出相机（快捷菜单"拍题"）。用过之后调用 `onCameraOpened`，不会再弹第二次。
    var autoOpenCamera = false
    var onCameraOpened: () -> Void = {}
    /// 学习助手通过本地工具查找内容，输入框不显示联网开关。
    var showsWebSearch = true

    @FocusState private var isFocused: Bool
    @State private var showPhotoPicker = false
    @State private var showCamera = false
    @State private var showHandwriting = false
    @State private var showPDFImporter = false
    @State private var pdfSource: PDFSource?
    @State private var pdfError = false
    @State private var photoItems: [PhotosPickerItem] = []
    /// 按钮的点按区域，跟随字号变大。
    @ScaledMetric(relativeTo: .title2) private var buttonSize: CGFloat = 34

    private var remainingSlots: Int {
        max(0, ImageCompressor.maxImagesPerMessage - images.count)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.s) {
            if !images.isEmpty {
                pendingImages
                if images.count > ImageCompressor.costWarningThreshold {
                    Label("已添加 \(images.count) 个附件（最多 \(ImageCompressor.maxImagesPerMessage) 个），图片较多，消耗会明显增加。",
                          systemImage: "info.circle")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            TextField(placement == .inline ? "问点什么" : "发消息", text: $text, axis: .vertical)
                .lineLimit(placement == .inline ? 2...8 : 1...6)
                .focused($isFocused)
                .padding(.horizontal, Theme.Spacing.s)
                .padding(.top, Theme.Spacing.xs)

            HStack(spacing: Theme.Spacing.xs) {
                attachmentMenu
                if showsWebSearch { webSearchButton }
                ModelPickerMenu(selection: $model, style: .compact)
                Spacer(minLength: Theme.Spacing.xs)
                sendButton
            }
        }
        .padding(Theme.Spacing.s)
        .background { surface }
        .task {
            if autoOpenCamera {
                onCameraOpened()
                if imagesAllowed && CameraPicker.isAvailable {
                    try? await Task.sleep(for: .milliseconds(400))
                    showCamera = true
                    return
                }
            }
            guard autoFocus else { return }
            // 等页面推入的动画走完再弹键盘，不然键盘和页面一起动，看着乱。
            try? await Task.sleep(for: .milliseconds(400))
            isFocused = true
        }
        .padding(.horizontal, placement == .bottomBar ? Theme.Spacing.m : 0)
        .padding(.bottom, placement == .bottomBar ? Theme.Spacing.s : 0)
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

    /// 卡片的底：聊天页用玻璃效果（消息可以从下面滚过去），"今天"页用白色卡片。都带一层淡阴影，看起来是浮起的。
    @ViewBuilder
    private var surface: some View {
        let shape = RoundedRectangle(cornerRadius: Theme.fieldRadius, style: .continuous)
        switch placement {
        case .bottomBar:
            Color.clear
                .glassSurface(in: shape)
                .shadow(color: .black.opacity(0.08), radius: 12, y: 4)
        case .inline:
            shape
                .fill(Color(.secondarySystemGroupedBackground))
                .shadow(color: .black.opacity(0.06), radius: 10, y: 3)
        }
    }

    /// 实心圆形的发送按钮；生成中变成停止按钮。
    private var sendButton: some View {
        let enabled = isGenerating || canSend
        return Button {
            isGenerating ? onStop() : onSend()
        } label: {
            Image(systemName: isGenerating ? "stop.fill" : "arrow.up")
                .font(.body.weight(.bold))
                .foregroundStyle(isGenerating ? Color(.systemBackground) : (enabled ? Color.white : Color(.tertiaryLabel)))
                .contentTransition(.symbolEffect(.replace))
                .frame(width: buttonSize, height: buttonSize)
                .background(
                    Circle().fill(isGenerating ? Color.primary : (enabled ? Color.accentColor : Color(.tertiarySystemFill)))
                )
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .accessibilityLabel(isGenerating ? "停止生成" : "发送")
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
                .font(.title3)
                .symbolEffect(.bounce, value: webSearchEnabled)
                .foregroundStyle(isOn ? AnyShapeStyle(.white) : (webSearchAllowed ? AnyShapeStyle(.tint) : AnyShapeStyle(.tertiary)))
                .frame(width: buttonSize, height: buttonSize)
                .background(isOn ? AnyShapeStyle(.tint) : AnyShapeStyle(.clear), in: Circle())
        }
        .accessibilityLabel("联网搜索")
        .accessibilityValue(isOn ? "已打开" : "已关闭")
    }

    private var attachmentIcon: some View {
        Image(systemName: "plus")
            .font(.title3)
            .frame(width: buttonSize, height: buttonSize)
            .accessibilityLabel("添加附件")
    }

    private var pendingImages: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: Theme.Spacing.s) {
                ForEach(images) { image in
                    Image(uiImage: image.thumbnail)
                        .resizable()
                        .scaledToFill()
                        .frame(width: 64, height: 64)
                        .clipShape(RoundedRectangle(cornerRadius: Theme.cardRadius, style: .continuous))
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
            .padding(.top, Theme.Spacing.s)
            .padding(.trailing, Theme.Spacing.s)
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
