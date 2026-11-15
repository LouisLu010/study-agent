import SwiftUI
import UIKit
import WebKit

/// 已渲染消息的高度缓存。LazyVStack 回收再重建 WebView 时用它做初始高度，避免列表跳动。
@MainActor
enum RenderCache {
    static var heights: [UUID: CGFloat] = [:]
}

/// 用 WebView 渲染一条模型消息（Markdown、公式、化学式、代码、坐标图），见 docs/adr/0003。
struct MessageWebView: UIViewRepresentable {
    let messageID: UUID
    let content: String
    let isStreaming: Bool
    @Binding var height: CGFloat
    var onFormulaTap: (String) -> Void = { _ in }

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeUIView(context: Context) -> WKWebView {
        let coordinator = context.coordinator
        coordinator.parent = self

        let controller = WKUserContentController()
        let handler = WeakScriptMessageHandler(target: coordinator)
        for name in Coordinator.messageNames {
            controller.add(handler, name: name)
        }

        let configuration = WKWebViewConfiguration()
        configuration.userContentController = controller
        configuration.dataDetectorTypes = []

        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.isOpaque = false
        webView.backgroundColor = .clear
        webView.scrollView.backgroundColor = .clear
        webView.scrollView.isScrollEnabled = false
        webView.scrollView.bounces = false
        webView.scrollView.contentInsetAdjustmentBehavior = .never
        webView.navigationDelegate = coordinator
        coordinator.webView = webView
        coordinator.loadRenderer()
        return webView
    }

    func updateUIView(_ webView: WKWebView, context: Context) {
        context.coordinator.parent = self
        context.coordinator.update(content: content, isStreaming: isStreaming)
    }

    static func dismantleUIView(_ webView: WKWebView, coordinator: Coordinator) {
        coordinator.cancelPendingRender()
        for name in Coordinator.messageNames {
            webView.configuration.userContentController.removeScriptMessageHandler(forName: name)
        }
    }

    @MainActor
    final class Coordinator: NSObject, WKNavigationDelegate {
        static let messageNames = ["ready", "height", "formula", "copy"]

        var parent: MessageWebView?
        weak var webView: WKWebView?

        private var isReady = false
        private var rendered: (content: String, isStreaming: Bool)?
        private var pending: (content: String, isStreaming: Bool)?
        private var throttleTask: Task<Void, Never>?

        func loadRenderer() {
            guard let webView,
                  let url = Bundle.main.url(forResource: "index", withExtension: "html", subdirectory: "Renderer")
            else { return }
            isReady = false
            webView.loadFileURL(url, allowingReadAccessTo: url.deletingLastPathComponent())
        }

        func update(content: String, isStreaming: Bool) {
            if let rendered, rendered.content == content, rendered.isStreaming == isStreaming {
                return
            }
            pending = (content, isStreaming)
            guard isReady else { return }

            if isStreaming {
                // 生成过程中最多每 80 毫秒渲染一次。
                guard throttleTask == nil else { return }
                throttleTask = Task { [weak self] in
                    try? await Task.sleep(for: .milliseconds(80))
                    guard !Task.isCancelled else { return }
                    self?.throttleTask = nil
                    self?.flush()
                }
            } else {
                cancelPendingRender()
                flush()
            }
        }

        func cancelPendingRender() {
            throttleTask?.cancel()
            throttleTask = nil
        }

        private func flush() {
            guard let webView, let next = pending else { return }
            pending = nil
            rendered = next
            webView.callAsyncJavaScript(
                "window.StudyRenderer.render(text, streaming)",
                arguments: ["text": next.content, "streaming": next.isStreaming],
                in: nil,
                in: .page,
                completionHandler: nil
            )
        }

        func receive(name: String, body: Any) {
            switch name {
            case "ready":
                isReady = true
                if pending == nil, let rendered {
                    pending = rendered
                }
                flush()
            case "height":
                guard let value = (body as? NSNumber)?.doubleValue, let parent else { return }
                let height = CGFloat(value)
                RenderCache.heights[parent.messageID] = height
                if abs(parent.height - height) > 0.5 {
                    parent.height = height
                }
            case "formula":
                if let tex = body as? String, !tex.isEmpty {
                    parent?.onFormulaTap(tex)
                }
            case "copy":
                if let text = body as? String {
                    UIPasteboard.general.string = text
                }
            default:
                break
            }
        }

        // MARK: WKNavigationDelegate

        func webView(
            _ webView: WKWebView,
            decidePolicyFor navigationAction: WKNavigationAction
        ) async -> WKNavigationActionPolicy {
            // 点链接时用系统浏览器打开，WebView 本身只显示渲染器页面。
            if navigationAction.navigationType == .linkActivated, let url = navigationAction.request.url {
                if url.scheme == "http" || url.scheme == "https" {
                    await UIApplication.shared.open(url)
                }
                return .cancel
            }
            return .allow
        }

        func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
            // WebView 进程被系统回收后重新加载，并恢复上次的内容。
            if pending == nil {
                pending = rendered
            }
            rendered = nil
            loadRenderer()
        }
    }
}

/// WKUserContentController 会强引用消息处理者，这里用弱引用避免循环引用。
@MainActor
private final class WeakScriptMessageHandler: NSObject, WKScriptMessageHandler {
    weak var target: MessageWebView.Coordinator?

    init(target: MessageWebView.Coordinator) {
        self.target = target
    }

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        target?.receive(name: message.name, body: message.body)
    }
}
