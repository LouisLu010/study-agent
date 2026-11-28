import StudyKit
import UIKit
import WebKit

/// 把汇编排成 A4 竖版 PDF：用渲染器排版（公式、化学式、原图和 App 里看到的一样），
/// 再用 UIPrintPageRenderer 分页，加页眉（汇编标题）和页脚（页码）。PDF 里不放出处链接。
@MainActor
enum CompilationPDF {
    struct Document: Encodable, Equatable {
        struct Question: Encodable, Equatable {
            let label: String
            let content: String
            let answer: String
            let answerLabel: String
            /// 整理时定的组名，组名变了就印一个组标题。
            let group: String
        }

        let title: String
        let subtitle: String
        let includeAnswers: Bool
        let questions: [Question]
    }

    enum GenerationError: LocalizedError, Equatable {
        case contentChanged

        var errorDescription: String? {
            "排版期间汇编内容发生了变化，请重新生成 PDF。"
        }
    }

    /// A4，单位是点。
    static let pageSize = CGSize(width: 595.2, height: 841.8)
    static let margins = UIEdgeInsets(top: 54, left: 50, bottom: 54, right: 50)

    static func document(for compilation: Compilation) -> Document {
        let questions = compilation.sortedQuestions
        return Document(
            title: compilation.title,
            subtitle: "共 \(questions.count) 题" + (compilation.request == compilation.title ? "" : " · \(compilation.request)"),
            includeAnswers: compilation.includeAnswers,
            questions: questions.map { question in
                Document.Question(
                    label: question.label,
                    content: question.content,
                    answer: question.answer,
                    answerLabel: answerLabel(question),
                    group: question.groupName
                )
            }
        )
    }

    static func answerLabel(_ question: ExamQuestion) -> String {
        switch question.answerKind {
        case .official: "官方答案"
        case .site: question.answerSite.isEmpty ? "网站解析" : "网站解析 · \(question.answerSite)"
        case .ai: "AI 解析"
        case .none: ""
        }
    }

    /// 渲染使用固定快照，发布前还要确认当前汇编与它一致。
    static func make(_ document: Document) async throws -> Data {
        let json = String(decoding: try JSONEncoder().encode(document), as: UTF8.self)

        let configuration = WKWebViewConfiguration()
        configuration.setURLSchemeHandler(AssetSchemeHandler.shared, forURLScheme: AssetSchemeHandler.scheme)
        let width = pageSize.width - margins.left - margins.right
        let webView = WKWebView(frame: CGRect(x: 0, y: 0, width: width, height: pageSize.height), configuration: configuration)
        webView.overrideUserInterfaceStyle = .light
        // 放进窗口但移到屏幕外：不在视图层级里时，有的系统版本不排版图片。
        let window = UIApplication.shared.connectedScenes.compactMap { ($0 as? UIWindowScene)?.keyWindow }.first
        webView.frame.origin = CGPoint(x: -width - 100, y: 0)
        window?.addSubview(webView)
        defer {
            webView.stopLoading()
            webView.navigationDelegate = nil
            webView.removeFromSuperview()
        }

        let loader = PageLoader()
        webView.navigationDelegate = loader
        guard let url = Bundle.main.url(forResource: "index", withExtension: "html", subdirectory: "Renderer") else {
            throw CocoaError(.fileNoSuchFile)
        }
        webView.loadFileURL(url, allowingReadAccessTo: url.deletingLastPathComponent())
        try await loader.wait()
        try Task.checkCancellation()

        let height = try await webView.callAsyncJavaScript(
            "return await window.StudyRenderer.renderPrint(JSON.parse(doc))",
            arguments: ["doc": json],
            contentWorld: .page
        )
        if let height = (height as? NSNumber)?.doubleValue, height > 0 {
            webView.frame.size.height = height
        }
        // 等一帧，让布局用上新的高度。
        try await Task.sleep(for: .milliseconds(150))

        let renderer = PageRenderer(title: document.title)
        renderer.addPrintFormatter(webView.viewPrintFormatter(), startingAtPageAt: 0)
        let paper = CGRect(origin: .zero, size: pageSize)
        let printable = paper.inset(by: margins)
        renderer.setValue(NSValue(cgRect: paper), forKey: "paperRect")
        renderer.setValue(NSValue(cgRect: printable), forKey: "printableRect")

        let data = NSMutableData()
        UIGraphicsBeginPDFContextToData(data, paper, [kCGPDFContextTitle as String: document.title])
        renderer.prepare(forDrawingPages: NSRange(location: 0, length: renderer.numberOfPages))
        for page in 0..<renderer.numberOfPages {
            UIGraphicsBeginPDFPage()
            renderer.drawPage(at: page, in: UIGraphicsGetPDFContextBounds())
        }
        UIGraphicsEndPDFContext()
        return data as Data
    }

    /// await 排版时答案、题目或选项可能已更新，旧文档不能覆盖当前缓存。
    static func publish(_ data: Data, for compilation: Compilation, snapshot: Document) throws {
        guard document(for: compilation) == snapshot else { throw GenerationError.contentChanged }
        compilation.pdfData = data
        compilation.pdfGeneratedAt = .now
        compilation.pdfPending = false
    }

    /// 等页面加载完。
    @MainActor
    final class PageLoader: NSObject, WKNavigationDelegate {
        private var continuation: CheckedContinuation<Void, any Error>?
        private var result: Result<Void, any Error>?
        private var timeoutTask: Task<Void, Never>?

        func wait(timeout: Duration = .seconds(30)) async throws {
            try Task.checkCancellation()
            if let result { return try result.get() }
            try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { continuation in
                    self.continuation = continuation
                    timeoutTask = Task { [weak self] in
                        do { try await Task.sleep(for: timeout) } catch { return }
                        self?.finish(.failure(URLError(.timedOut)))
                    }
                }
            } onCancel: {
                Task { @MainActor [weak self] in self?.finish(.failure(CancellationError())) }
            }
        }

        private func finish(_ result: Result<Void, any Error>) {
            guard self.result == nil else { return }
            self.result = result
            timeoutTask?.cancel()
            timeoutTask = nil
            continuation?.resume(with: result)
            continuation = nil
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            finish(.success(()))
        }

        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: any Error) {
            finish(.failure(error))
        }

        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: any Error) {
            finish(.failure(error))
        }

        func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
            finish(.failure(URLError(.networkConnectionLost)))
        }
    }

    /// 页眉写汇编标题，页脚写页码。
    @MainActor
    private final class PageRenderer: UIPrintPageRenderer {
        let title: String

        init(title: String) {
            self.title = title
            super.init()
            headerHeight = 30
            footerHeight = 30
        }

        private let attributes: [NSAttributedString.Key: Any] = [
            .font: UIFont.systemFont(ofSize: 8.5),
            .foregroundColor: UIColor.darkGray,
        ]

        override func drawHeaderForPage(at pageIndex: Int, in headerRect: CGRect) {
            let text = title as NSString
            let size = text.size(withAttributes: attributes)
            text.draw(at: CGPoint(x: headerRect.midX - size.width / 2, y: headerRect.maxY - size.height - 8), withAttributes: attributes)
            let path = UIBezierPath()
            path.move(to: CGPoint(x: headerRect.minX + CompilationPDF.margins.left, y: headerRect.maxY - 4))
            path.addLine(to: CGPoint(x: headerRect.maxX - CompilationPDF.margins.right, y: headerRect.maxY - 4))
            UIColor.lightGray.setStroke()
            path.lineWidth = 0.5
            path.stroke()
        }

        override func drawFooterForPage(at pageIndex: Int, in footerRect: CGRect) {
            let text = "第 \(pageIndex + 1) 页 / 共 \(numberOfPages) 页" as NSString
            let size = text.size(withAttributes: attributes)
            text.draw(at: CGPoint(x: footerRect.midX - size.width / 2, y: footerRect.minY + 8), withAttributes: attributes)
        }
    }
}
