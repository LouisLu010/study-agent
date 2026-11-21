import StudyKit
import SwiftData
import UIKit
import WebKit

/// App 共用的数据容器。WebView 的图片请求（`sa-asset:`）也从这里读。
@MainActor
enum AppStore {
    static let container: ModelContainer = {
        do {
            return try ModelContainer(for: Schema(StudyAgentSchema.models))
        } catch {
            fatalError("无法打开数据库：\(error)")
        }
    }()
}

/// 让渲染器能显示 App 里保存的图片：`![](sa-asset:<StoredImage.id>)`。
@MainActor
final class AssetSchemeHandler: NSObject, WKURLSchemeHandler {
    static let scheme = "sa-asset"
    static let shared = AssetSchemeHandler()

    /// 从 `sa-asset:<uuid>` 里取出 id。
    static func imageID(from url: URL) -> UUID? {
        let text = url.absoluteString
            .replacingOccurrences(of: scheme + ":", with: "")
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        return UUID(uuidString: text)
    }

    static func image(id: UUID, in context: ModelContext) -> StoredImage? {
        let descriptor = FetchDescriptor<StoredImage>(predicate: #Predicate { $0.id == id })
        return try? context.fetch(descriptor).first
    }

    func webView(_ webView: WKWebView, start urlSchemeTask: any WKURLSchemeTask) {
        guard let url = urlSchemeTask.request.url,
              let id = Self.imageID(from: url),
              let image = Self.image(id: id, in: AppStore.container.mainContext),
              let data = image.data
        else {
            urlSchemeTask.didFailWithError(URLError(.fileDoesNotExist))
            return
        }
        let response = URLResponse(
            url: url,
            mimeType: image.contentType,
            expectedContentLength: data.count,
            textEncodingName: nil
        )
        urlSchemeTask.didReceive(response)
        urlSchemeTask.didReceive(data)
        urlSchemeTask.didFinish()
    }

    func webView(_ webView: WKWebView, stop urlSchemeTask: any WKURLSchemeTask) {}
}

/// 下载题库网页和图片。用 iPhone Safari 的 User-Agent，有的网站会拒绝其他客户端。
enum PageFetcher {
    static let userAgent = "Mozilla/5.0 (iPhone; CPU iPhone OS 18_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Mobile/15E148 Safari/604.1"

    enum FetchError: LocalizedError {
        case http(Int)
        case notImage

        var errorDescription: String? {
            switch self {
            case let .http(status): "网页返回 HTTP \(status)"
            case .notImage: "不是图片"
            }
        }
    }

    private static func request(_ url: URL, referer: URL? = nil) -> URLRequest {
        var request = URLRequest(url: url, timeoutInterval: 25)
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("zh-CN,zh;q=0.9", forHTTPHeaderField: "Accept-Language")
        if let referer { request.setValue(referer.absoluteString, forHTTPHeaderField: "Referer") }
        return request
    }

    /// 下载网页并按网页声明的编码解码（有的网站还在用 GBK）。
    static func html(_ url: URL) async throws -> String {
        let (data, response) = try await URLSession.shared.data(for: request(url))
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw FetchError.http(http.statusCode)
        }
        let header = (response as? HTTPURLResponse)?.value(forHTTPHeaderField: "Content-Type") ?? ""
        let head = String(decoding: data.prefix(4096), as: UTF8.self)
        let declared = (header + " " + head).lowercased()
        if declared.contains("gb2312") || declared.contains("gbk") || declared.contains("gb18030") {
            let encoding = String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(
                CFStringEncoding(CFStringEncodings.GB_18030_2000.rawValue)
            ))
            if let text = String(data: data, encoding: encoding) { return text }
        }
        return String(decoding: data, as: UTF8.self)
    }

    /// 下载一张图片，失败时重试两次。返回数据和 MIME 类型。
    static func image(_ url: URL, referer: URL) async throws -> (Data, String) {
        var lastError: any Error = FetchError.notImage
        for attempt in 0..<3 {
            if attempt > 0 { try await Task.sleep(for: .milliseconds(600 * attempt)) }
            do {
                let (data, response) = try await URLSession.shared.data(for: request(url, referer: referer))
                let http = response as? HTTPURLResponse
                if let status = http?.statusCode, !(200..<300).contains(status) { throw FetchError.http(status) }
                var type = (http?.value(forHTTPHeaderField: "Content-Type") ?? "").components(separatedBy: ";")[0]
                    .trimmingCharacters(in: .whitespaces).lowercased()
                if !type.hasPrefix("image/") {
                    // 有的图床不给类型，按内容判断。
                    if data.starts(with: [0x89, 0x50, 0x4E, 0x47]) { type = "image/png" }
                    else if data.starts(with: [0xFF, 0xD8]) { type = "image/jpeg" }
                    else if data.starts(with: Array("GIF8".utf8)) { type = "image/gif" }
                    else if String(decoding: data.prefix(300), as: UTF8.self).contains("<svg") { type = "image/svg+xml" }
                    else { throw FetchError.notImage }
                }
                guard data.count > 100 else { throw FetchError.notImage }
                return (data, type)
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                lastError = error
            }
        }
        throw lastError
    }
}
