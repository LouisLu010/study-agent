import SwiftUI
import UIKit

enum ImageCompressor {
    static let maxDimension: CGFloat = 2048
    static let quality: CGFloat = 0.8
    /// 每条消息最多附带的附件数（照片、PDF 页面、手写一起计数）。
    static let maxImagesPerMessage = 10
    /// 超过这个数时提示消耗会明显增加。
    static let costWarningThreshold = 4

    /// 把图片缩小到长边不超过 2048 像素，再转成 JPEG。原图不保存。
    static func jpegData(from image: UIImage) -> Data? {
        let size = image.size
        let longest = max(size.width, size.height)
        guard longest > 0 else { return nil }
        let scale = min(1, maxDimension / longest)
        let target = CGSize(width: (size.width * scale).rounded(), height: (size.height * scale).rounded())

        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        let resized = UIGraphicsImageRenderer(size: target, format: format).image { _ in
            UIColor.white.setFill()
            UIRectFill(CGRect(origin: .zero, size: target))
            image.draw(in: CGRect(origin: .zero, size: target))
        }
        return resized.jpegData(compressionQuality: quality)
    }

    static func jpegData(from data: Data) -> Data? {
        UIImage(data: data).flatMap(jpegData(from:))
    }
}

/// 输入框里还没发送的图片。
struct PendingImage: Identifiable {
    let id = UUID()
    let data: Data
    let thumbnail: UIImage

    init?(jpeg data: Data) {
        guard let image = UIImage(data: data) else { return nil }
        self.data = data
        self.thumbnail = image.preparingThumbnail(of: CGSize(width: 160, height: 160)) ?? image
    }
}

/// 拍照。
struct CameraPicker: UIViewControllerRepresentable {
    var onImage: (UIImage) -> Void
    @Environment(\.dismiss) private var dismiss

    static var isAvailable: Bool {
        UIImagePickerController.isSourceTypeAvailable(.camera)
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    func makeUIViewController(context: Context) -> UIImagePickerController {
        let picker = UIImagePickerController()
        picker.sourceType = .camera
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ controller: UIImagePickerController, context: Context) {}

    @MainActor
    final class Coordinator: NSObject, UIImagePickerControllerDelegate, UINavigationControllerDelegate {
        let parent: CameraPicker

        init(parent: CameraPicker) {
            self.parent = parent
        }

        func imagePickerController(
            _ picker: UIImagePickerController,
            didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]
        ) {
            if let image = info[.originalImage] as? UIImage {
                parent.onImage(image)
            }
            parent.dismiss()
        }

        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) {
            parent.dismiss()
        }
    }
}

/// 从 Data 异步解码的缩略图，避免每次刷新界面都重新解码。
struct ThumbnailView: View {
    let data: Data
    var size: CGFloat = 120

    @State private var image: UIImage?

    var body: some View {
        Group {
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
            } else {
                Rectangle().fill(.quaternary)
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .task(id: data) {
            let pixel = size * 3
            image = await UIImage(data: data)?.byPreparingThumbnail(ofSize: CGSize(width: pixel, height: pixel))
        }
    }
}
