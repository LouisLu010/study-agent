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
    /// 这条消息保存的组件状态（JSON）。只在 WebView 首次渲染时传给渲染器，之后由渲染器自己维护。
    var componentStateJSON: String = ""
    /// 组件格式有误时，提示卡片上是否显示"重新生成"按钮。
    var canRegenerate: Bool = false
    @Binding var height: CGFloat
    var onFormulaTap: (String) -> Void = { _ in }
    /// 组件状态变化。state 为 nil 表示复位。
    var onComponentState: (String, Any?) -> Void = { _, _ in }
    /// 组件里的"问问 AI"按钮。
    var onAsk: (String) -> Void = { _ in }
    var onRegenerate: () -> Void = {}
    /// 测验里答完一道题：{ question, answer, correct }。
    var onQuizResult: ([String: Any]) -> Void = { _ in }
    /// 答错的题会自动加入错题本时为 true，测验组件会在结果里提示一句。
    var recordsMistakes = false
    /// 放在浅灰底的分组页面上时为 true，组件卡片改成白色。
    var groupedSurface = false
    /// 外面用来截长图的引用。
    var handle: WebViewHandle?

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
        configuration.setURLSchemeHandler(AssetSchemeHandler.shared, forURLScheme: AssetSchemeHandler.scheme)

        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.isOpaque = false
        webView.backgroundColor = .clear
        webView.scrollView.backgroundColor = .clear
        webView.scrollView.isScrollEnabled = false
        webView.scrollView.bounces = false
        webView.scrollView.contentInsetAdjustmentBehavior = .never
        webView.navigationDelegate = coordinator
        coordinator.webView = webView
        handle?.webView = webView
        coordinator.loadRenderer()
        return webView
    }

    func updateUIView(_ webView: WKWebView, context: Context) {
        context.coordinator.parent = self
        context.coordinator.update(content: content, isStreaming: isStreaming)
        context.coordinator.updateCanRegenerate(canRegenerate)
    }

    static func dismantleUIView(_ webView: WKWebView, coordinator: Coordinator) {
        coordinator.cancelPendingRender()
        // 手势进行中 WebView 被回收时，别让聊天列表一直不能滚动。
        coordinator.setOuterScrollLocked(false)
        for name in Coordinator.messageNames {
            webView.configuration.userContentController.removeScriptMessageHandler(forName: name)
        }
    }

    @MainActor
    final class Coordinator: NSObject, WKNavigationDelegate {
        static let messageNames = ["ready", "height", "formula", "copy", "state", "ask", "regenerate", "scrollLock", "quizResult"]

        /// 被暂停滚动的聊天列表。手势结束或 WebView 被回收时恢复。
        private weak var lockedScrollView: UIScrollView?

        /// 组件开始处理手势时暂停外层聊天列表的滚动，结束后恢复。
        /// 关掉再打开 panGestureRecognizer 会立即取消已经开始的滚动。
        func setOuterScrollLocked(_ locked: Bool) {
            if locked {
                guard lockedScrollView == nil, let scrollView = enclosingScrollView() else { return }
                scrollView.panGestureRecognizer.isEnabled = false
                lockedScrollView = scrollView
            } else {
                lockedScrollView?.panGestureRecognizer.isEnabled = true
                lockedScrollView = nil
            }
        }

        /// WebView 外面最近的 UIScrollView（SwiftUI 的 ScrollView 底层就是它）。
        private func enclosingScrollView() -> UIScrollView? {
            var view = webView?.superview
            while let current = view {
                if let scrollView = current as? UIScrollView { return scrollView }
                view = current.superview
            }
            return nil
        }

        var parent: MessageWebView?
        weak var webView: WKWebView?

        private var isReady = false
        /// 页面加载后是否已经把保存的组件状态交给渲染器。
        private var didSendInitialOptions = false
        private var sentCanRegenerate: Bool?
        private var rendered: (content: String, isStreaming: Bool)?
        private var pending: (content: String, isStreaming: Bool)?
        private var throttleTask: Task<Void, Never>?

        func loadRenderer() {
            guard let webView,
                  let url = Bundle.main.url(forResource: "index", withExtension: "html", subdirectory: "Renderer")
            else { return }
            isReady = false
            didSendInitialOptions = false
            sentCanRegenerate = nil
            webView.loadFileURL(url, allowingReadAccessTo: url.deletingLastPathComponent())
        }

        func updateCanRegenerate(_ value: Bool) {
            guard isReady, didSendInitialOptions, sentCanRegenerate != value, let webView else { return }
            sentCanRegenerate = value
            webView.callAsyncJavaScript(
                "window.StudyRenderer.setOptions({ canRegenerate })",
                arguments: ["canRegenerate": value],
                in: nil,
                in: .page,
                completionHandler: nil
            )
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

            if didSendInitialOptions {
                webView.callAsyncJavaScript(
                    "window.StudyRenderer.render(text, streaming)",
                    arguments: ["text": next.content, "streaming": next.isStreaming],
                    in: nil,
                    in: .page,
                    completionHandler: nil
                )
            } else {
                // 第一次渲染时带上保存的组件状态，组件据此恢复滑块位置、测验答案等。
                didSendInitialOptions = true
                let canRegenerate = parent?.canRegenerate ?? false
                sentCanRegenerate = canRegenerate
                webView.callAsyncJavaScript(
                    """
                    let state = {};
                    try { state = stateJSON ? JSON.parse(stateJSON) : {}; } catch (e) {}
                    window.StudyRenderer.render(text, streaming, { state, canRegenerate, recordsMistakes, grouped });
                    """,
                    arguments: [
                        "text": next.content,
                        "streaming": next.isStreaming,
                        "stateJSON": parent?.componentStateJSON ?? "",
                        "canRegenerate": canRegenerate,
                        "recordsMistakes": parent?.recordsMistakes ?? false,
                        "grouped": parent?.groupedSurface ?? false,
                    ],
                    in: nil,
                    in: .page,
                    completionHandler: nil
                )
            }
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
            case "state":
                guard let payload = body as? [String: Any], let key = payload["key"] as? String else { return }
                parent?.onComponentState(key, payload["state"])
            case "ask":
                if let text = body as? String, !text.isEmpty {
                    parent?.onAsk(text)
                }
            case "quizResult":
                if let payload = body as? [String: Any] {
                    parent?.onQuizResult(payload)
                }
            case "scrollLock":
                setOuterScrollLocked((body as? NSNumber)?.boolValue ?? false)
            case "regenerate":
                if parent?.canRegenerate == true {
                    parent?.onRegenerate()
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
            setOuterScrollLocked(false)
            // WebView 进程被系统回收后重新加载，并恢复上次的内容。
            if pending == nil {
                pending = rendered
            }
            rendered = nil
            loadRenderer()
        }
    }
}

extension WKWebView: WKWebViewSnapshotting {
    /// WebView 的高度就是内容高度（自身不滚动），所以截下整个边界就是整条回答。
    func snapshotFullContent() async -> UIImage? {
        let configuration = WKSnapshotConfiguration()
        configuration.rect = bounds
        configuration.afterScreenUpdates = true
        return try? await takeSnapshot(configuration: configuration)
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
