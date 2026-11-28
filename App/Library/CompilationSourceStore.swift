import CryptoKit
import Foundation

/// 已经取得的原始网页保存在设备上，后续汇编可以直接读取，不必重新搜索来源。
@MainActor
final class CompilationSourceStore {
    nonisolated static let defaultCapacityBytes = 100 * 1024 * 1024

    enum StoreError: LocalizedError {
        case invalidURL

        var errorDescription: String? {
            switch self {
            case .invalidURL: "试卷来源必须是不含账号密码的 HTTP 或 HTTPS 网页。"
            }
        }
    }

    private struct Entry: Codable {
        let version: Int
        let url: String
        let html: String
        let digest: String
    }

    private let directory: URL
    private let download: (URL) async throws -> String
    private let capacityBytes: Int
    private let files = FileManager.default

    init(
        directory: URL? = nil,
        download: @escaping (URL) async throws -> String = PageFetcher.html,
        capacityBytes: Int = CompilationSourceStore.defaultCapacityBytes
    ) {
        self.directory = directory ?? URL.applicationSupportDirectory.appending(path: "CompilationSources", directoryHint: .isDirectory)
        self.download = download
        self.capacityBytes = max(0, capacityBytes)
        prune()
    }

    func html(for url: URL) async throws -> String {
        try Task.checkCancellation()
        let url = try Self.normalizedURL(url)
        let file = directory.appending(path: Self.digest(Data(url.absoluteString.utf8)) + ".source")
        if let html = read(file, for: url) { return html }

        let html = try await download(url)
        try Task.checkCancellation()
        guard html.utf8.count <= PageFetcher.maxHTMLBytes else { throw PageFetcher.FetchError.pageTooLarge }
        if !html.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            save(html, for: url, to: file)
        }
        return html
    }

    /// 页面暂时返回登录或反爬提示、或者用户明确重新获取时，允许下一次访问重新下载。
    func invalidate(for url: URL) {
        guard let url = try? Self.normalizedURL(url) else { return }
        let file = directory.appending(path: Self.digest(Data(url.absoluteString.utf8)) + ".source")
        try? files.removeItem(at: file)
    }

    /// fragment 只指向网页内的位置，不改变下载内容；查询参数仍原样保留。
    static func normalizedURL(_ url: URL) throws -> URL {
        guard var parts = URLComponents(url: url, resolvingAgainstBaseURL: true),
              let scheme = parts.scheme?.lowercased(), ["http", "https"].contains(scheme),
              let host = parts.host, !host.isEmpty, parts.user == nil, parts.password == nil
        else { throw StoreError.invalidURL }
        parts.scheme = scheme
        parts.host = host.lowercased()
        parts.fragment = nil
        guard let normalized = parts.url else { throw StoreError.invalidURL }
        return normalized
    }

    private static func digest(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private func read(_ file: URL, for url: URL) -> String? {
        guard files.fileExists(atPath: file.path) else { return nil }
        do {
            let attributes = try file.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
            // binary plist 的 Unicode 字符串最多占两倍 UTF-8 大小，另外留少量元数据空间。
            guard attributes.isRegularFile == true, attributes.isSymbolicLink != true,
                  let size = attributes.fileSize, size <= PageFetcher.maxHTMLBytes * 2 + 16_384
            else { throw CocoaError(.fileReadCorruptFile) }
            let entry = try PropertyListDecoder().decode(Entry.self, from: Data(contentsOf: file))
            guard entry.version == 1, entry.url == url.absoluteString,
                  !entry.html.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  entry.html.utf8.count <= PageFetcher.maxHTMLBytes,
                  entry.digest == Self.digest(Data(entry.html.utf8))
            else { throw CocoaError(.fileReadCorruptFile) }
            try? files.setAttributes([.modificationDate: Date.now], ofItemAtPath: file.path)
            return entry.html
        } catch {
            // 只丢弃坏掉的缓存；原始来源仍可重新下载。
            try? files.removeItem(at: file)
            return nil
        }
    }

    private func save(_ html: String, for url: URL, to file: URL) {
        guard capacityBytes > 0 else { return }
        do {
            let entry = Entry(version: 1, url: url.absoluteString, html: html, digest: Self.digest(Data(html.utf8)))
            let encoder = PropertyListEncoder()
            encoder.outputFormat = .binary
            let data = try encoder.encode(entry)
            guard data.count <= capacityBytes else { return }
            try files.createDirectory(at: directory, withIntermediateDirectories: true)
            var attributes = URLResourceValues()
            attributes.isExcludedFromBackup = true
            var directory = directory
            try? directory.setResourceValues(attributes)
            try data.write(to: file, options: .atomic)
            prune()
        } catch {
            // 磁盘已满或不可写时，已经下载的网页仍能用于本次汇编。
        }
    }

    private func prune() {
        let keys: Set<URLResourceKey> = [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey, .contentModificationDateKey]
        guard let urls = try? files.contentsOfDirectory(at: directory, includingPropertiesForKeys: Array(keys)) else { return }
        let entries = urls.filter { $0.pathExtension == "source" }.compactMap { url -> (url: URL, size: Int, accessed: Date)? in
            guard let values = try? url.resourceValues(forKeys: keys),
                  values.isRegularFile == true, values.isSymbolicLink != true, let size = values.fileSize
            else { return nil }
            return (url, size, values.contentModificationDate ?? .distantPast)
        }.sorted { $0.accessed < $1.accessed }
        var total = entries.reduce(0) { $0 + $1.size }
        for entry in entries where total > capacityBytes {
            do {
                try files.removeItem(at: entry.url)
                total -= entry.size
            } catch {
                // 某个文件暂时不能删除时，继续淘汰其他旧页面。
            }
        }
    }
}
