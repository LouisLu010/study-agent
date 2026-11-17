import PencilKit
import SwiftUI
import UIKit

/// 手写画板。写完后导出成白底图片作为附件，由模型识别（App 本身不识别手写）。
struct HandwritingSheet: View {
    let onDone: (Data) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var canvas = HandwritingCanvasController()
    @State private var isEmpty = true

    var body: some View {
        NavigationStack {
            HandwritingCanvas(controller: canvas, isEmpty: $isEmpty)
                .background(GridBackground())
                .ignoresSafeArea(.container, edges: .bottom)
                .navigationTitle("手写")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("取消") { dismiss() }
                    }
                    ToolbarItemGroup(placement: .primaryAction) {
                        Button("撤销", systemImage: "arrow.uturn.backward") { canvas.undo() }
                            .disabled(isEmpty)
                        Button("清空", systemImage: "trash") { canvas.clear() }
                            .disabled(isEmpty)
                        Button("完成") {
                            if let data = canvas.exportJPEG() {
                                onDone(data)
                            }
                            dismiss()
                        }
                        .bold()
                        .disabled(isEmpty)
                    }
                }
        }
        .interactiveDismissDisabled(!isEmpty)
    }
}

/// 持有画布和工具栏。PKToolPicker 必须被强引用，否则会立即消失。
@MainActor
final class HandwritingCanvasController {
    let canvasView = PKCanvasView()
    let toolPicker = PKToolPicker()

    init() {
        canvasView.backgroundColor = .clear
        canvasView.isOpaque = false
        // iPad 上有 Apple Pencil 时手指用来滚动和缩放，没有时手指也能写；iPhone 上用手指写。
        canvasView.drawingPolicy = UIDevice.current.userInterfaceIdiom == .pad ? .default : .anyInput
        canvasView.tool = PKInkingTool(.pen, color: .black, width: 3)
        // 画布比屏幕大一些，写满了可以往下滚动继续写。
        canvasView.contentSize = CGSize(width: 1, height: 2400)
        canvasView.alwaysBounceVertical = true
    }

    func showToolPicker() {
        toolPicker.setVisible(true, forFirstResponder: canvasView)
        toolPicker.addObserver(canvasView)
        canvasView.becomeFirstResponder()
    }

    func undo() {
        canvasView.undoManager?.undo()
    }

    func clear() {
        canvasView.drawing = PKDrawing()
    }

    /// 只导出写过的区域（四周留一点边距），白底，按浅色模式渲染，避免深色模式下黑色笔迹变成白色。
    func exportJPEG() -> Data? {
        let drawing = canvasView.drawing
        guard !drawing.strokes.isEmpty else { return nil }
        let area = drawing.bounds.insetBy(dx: -40, dy: -40)
        var image = UIImage()
        UITraitCollection(userInterfaceStyle: .light).performAsCurrent {
            image = drawing.image(from: area, scale: 2)
        }
        return ImageCompressor.jpegData(from: image)
    }
}

private struct HandwritingCanvas: UIViewRepresentable {
    let controller: HandwritingCanvasController
    @Binding var isEmpty: Bool

    func makeCoordinator() -> Coordinator {
        Coordinator(isEmpty: $isEmpty)
    }

    func makeUIView(context: Context) -> PKCanvasView {
        let view = controller.canvasView
        view.delegate = context.coordinator
        Task { @MainActor in controller.showToolPicker() }
        return view
    }

    func updateUIView(_ view: PKCanvasView, context: Context) {
        if view.contentSize.width != view.bounds.width, view.bounds.width > 0 {
            view.contentSize = CGSize(width: view.bounds.width, height: max(2400, view.bounds.height * 2))
        }
    }

    @MainActor
    final class Coordinator: NSObject, PKCanvasViewDelegate {
        let isEmpty: Binding<Bool>

        init(isEmpty: Binding<Bool>) {
            self.isEmpty = isEmpty
        }

        func canvasViewDrawingDidChange(_ canvasView: PKCanvasView) {
            isEmpty.wrappedValue = canvasView.drawing.strokes.isEmpty
        }
    }
}

/// 浅色网格背景，方便对齐书写。只用于显示，导出的图片里没有网格。
private struct GridBackground: View {
    var body: some View {
        Canvas { context, size in
            let step: CGFloat = 32
            var path = Path()
            var x: CGFloat = 0
            while x <= size.width {
                path.move(to: CGPoint(x: x, y: 0))
                path.addLine(to: CGPoint(x: x, y: size.height))
                x += step
            }
            var y: CGFloat = 0
            while y <= size.height {
                path.move(to: CGPoint(x: 0, y: y))
                path.addLine(to: CGPoint(x: size.width, y: y))
                y += step
            }
            context.stroke(path, with: .color(Color(red: 0.85, green: 0.88, blue: 0.95)), lineWidth: 0.5)
        }
        .background(Color.white)
    }
}
