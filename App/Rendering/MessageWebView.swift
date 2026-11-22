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
    /// 这是全屏页（第八版）：画面更大，横屏时参数面板在侧边。
    var fullscreenSurface = false
    /// 模拟、坐标图、几何图卡片上的全屏按钮：(组件键, 只有这个组件的 Markdown, 它的状态 JSON)。为 nil 时不显示按钮。
    var onFullscreen: ((String, String, String) -> Void)?

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
        static let messageNames = ["ready", "height", "formula", "copy", "state", "ask", "regenerate", "scrollLock", "quizResult", "reveal", "fullscreen"]

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

        /// 分步讲解新展开的一步不在屏幕里时，把外面的列表滚过去（第八版）。WebView 自己不滚动，高度就是内容高度。
        private func reveal(top: Double, bottom: Double) {
            guard bottom > top else { return }
            // 等高度更新、列表重新排好后再滚。
            Task { @MainActor [weak self] in
                try? await Task.sleep(for: .milliseconds(150))
                guard let self, let webView = self.webView, let scrollView = self.enclosingScrollView() else { return }
                let rect = CGRect(x: 0, y: top, width: webView.bounds.width, height: bottom - top)
                let target = scrollView.convert(rect, from: webView).insetBy(dx: 0, dy: -24)
                let visible = CGRect(origin: scrollView.contentOffset, size: scrollView.bounds.size)
                    .inset(by: scrollView.adjustedContentInset)
                guard !visible.contains(target) else { return }
                scrollView.scrollRectToVisible(target, animated: true)
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
        /// 有一次渲染已经交给 WebView、还没算完。
        private var isRendering = false
        /// 上一次渲染在 WebView 里花了多久（秒）。
        private var lastRenderDuration: Double = 0

        func loadRenderer() {
            guard let webView,
                  let url = Bundle.main.url(forResource: "index", withExtension: "html", subdirectory: "Renderer")
            else { return }
            isReady = false
            isRendering = false
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
                scheduleStreamingFlush()
            } else {
                // 生成结束的那次完整渲染不等节流，但仍然排在正在算的那次后面。
                cancelPendingRender()
                if !isRendering { flush() }
            }
        }

        /// 生成过程中的节流：同一时间只有一次渲染在算；算完以后至少隔 80 毫秒、并且至少隔上一次花的时间那么久
        /// 才发下一次。以前固定每 80 毫秒发一次，公式多、回答长时一次渲染要几百毫秒，调用在 WebView 里排队，
        /// WebView 一直忙着算、没空画，高度又在不停变，整条回答就成了一片空白，要等生成完才出来。
        private func scheduleStreamingFlush() {
            guard throttleTask == nil, !isRendering else { return }
            let interval = max(0.08, min(1.5, lastRenderDuration))
            throttleTask = Task { [weak self] in
                try? await Task.sleep(for: .seconds(interval))
                guard !Task.isCancelled, let self else { return }
                self.throttleTask = nil
                self.flush()
            }
        }

        /// 一次渲染算完：记下用时；中间又来了新内容就接着排下一次。
        private func renderFinished(startedAt start: Date) {
            isRendering = false
            lastRenderDuration = Date().timeIntervalSince(start)
            guard let pending else { return }
            if pending.isStreaming {
                scheduleStreamingFlush()
            } else {
                flush()
            }
        }

        func cancelPendingRender() {
            throttleTask?.cancel()
            throttleTask = nil
        }

        private func flush() {
            guard let webView, let next = pending, !isRendering else { return }
            pending = nil
            rendered = next
            isRendering = true
            let start = Date()
            // 出错也算这次算完了（例如页面正在重新加载），不然后面的渲染会一直等着。
            let done: @Sendable (Result<Any, any Error>) -> Void = { [weak self] _ in
                let coordinator = self
                Task { @MainActor in coordinator?.renderFinished(startedAt: start) }
            }

            if didSendInitialOptions {
                webView.callAsyncJavaScript(
                    "window.StudyRenderer.render(text, streaming)",
                    arguments: ["text": next.content, "streaming": next.isStreaming],
                    in: nil,
                    in: .page,
                    completionHandler: done
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
                    window.StudyRenderer.render(text, streaming, { state, canRegenerate, recordsMistakes, grouped, fullscreen, canFullscreen });
                    """,
                    arguments: [
                        "text": next.content,
                        "streaming": next.isStreaming,
                        "stateJSON": parent?.componentStateJSON ?? "",
                        "canRegenerate": canRegenerate,
                        "recordsMistakes": parent?.recordsMistakes ?? false,
                        "grouped": parent?.groupedSurface ?? false,
                        "fullscreen": parent?.fullscreenSurface ?? false,
                        "canFullscreen": parent?.onFullscreen != nil,
                    ],
                    in: nil,
                    in: .page,
                    completionHandler: done
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
            case "fullscreen":
                guard let payload = body as? [String: Any],
                      let key = payload["key"] as? String,
                      let markdown = payload["markdown"] as? String
                else { return }
                parent?.onFullscreen?(key, markdown, payload["state"] as? String ?? "")
            case "reveal":
                guard let payload = body as? [String: Any],
                      let top = (payload["top"] as? NSNumber)?.doubleValue,
                      let bottom = (payload["bottom"] as? NSNumber)?.doubleValue
                else { return }
                reveal(top: top, bottom: bottom)
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

extension WebViewHandle {
    /// 全屏页关掉后，把这条消息保存的组件状态里这一个组件的状态交回给正文里的组件，它会按新状态重画。
    func applyState(key: String, stateJSON: String) {
        guard let webView = webView as? WKWebView else { return }
        webView.callAsyncJavaScript(
            """
            let all = {};
            try { all = json ? JSON.parse(json) : {}; } catch (e) {}
            window.StudyComponents.applyState(key, Object.prototype.hasOwnProperty.call(all, key) ? all[key] : null);
            """,
            arguments: ["key": key, "json": stateJSON],
            in: nil,
            in: .page,
            completionHandler: nil
        )
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
