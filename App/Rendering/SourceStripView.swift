import Observation
import StudyKit
import SwiftUI
import UIKit

/// 联网搜索的回答上方横排一行出处卡片（第八版）：网站图标、标题、域名，左右滑动。
/// 拿到出处就显示，不等生成完。最后一张是"全部 N 个"，点开看完整列表。
struct SourceStripView: View {
    let sources: [WebSource]
    /// 有引用时按 [1] [2] 编号，和正文里的角标一致；只有搜索结果时不编号。
    let numbered: Bool

    @State private var showsAll = false

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(alignment: .top, spacing: Theme.Spacing.s) {
                ForEach(sources.indices, id: \.self) { index in
                    if let url = URL(string: sources[index].url) {
                        Link(destination: url) {
                            SourceCard(source: sources[index], number: numbered ? index + 1 : nil)
                        }
                        .buttonStyle(.plain)
                    }
                }
                Button {
                    showsAll = true
                } label: {
                    VStack(spacing: Theme.Spacing.xs) {
                        Image(systemName: "list.bullet")
                            .font(.headline)
                        Text("全部 \(sources.count) 个")
                            .font(.footnote)
                    }
                    .foregroundStyle(.tint)
                    .frame(width: 88, height: SourceCard.height)
                    .cardBackground()
                }
                .buttonStyle(.plain)
            }
        }
        .scrollClipDisabled()
        .sheet(isPresented: $showsAll) {
            NavigationStack {
                ScrollView {
                    SourceListView(sources: sources, numbered: numbered)
                        .padding(Theme.Spacing.l)
                }
                .navigationTitle("出处")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("完成") { showsAll = false }
                    }
                }
            }
            .presentationDetents([.medium, .large])
        }
    }
}

/// 一张出处卡片。
private struct SourceCard: View {
    static let height: CGFloat = 76

    let source: WebSource
    let number: Int?

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
            HStack(spacing: 6) {
                FaviconView(host: source.siteHost)
                Text(source.host ?? source.url)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Spacer(minLength: 0)
                if let number {
                    Text("\(number)")
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }
            Text(source.displayTitle)
                .font(.footnote)
                .foregroundStyle(.primary)
                .lineLimit(2)
                .multilineTextAlignment(.leading)
            Spacer(minLength: 0)
        }
        .padding(Theme.Spacing.s)
        .frame(width: 176, height: Self.height, alignment: .topLeading)
        .cardBackground()
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityHint("用浏览器打开")
    }
}

extension WebSource {
    /// 下载网站图标用的域名（保留 www.），只认普通的域名字符。
    var siteHost: String? {
        guard let host = URL(string: url)?.host()?.lowercased(),
              !host.isEmpty, host.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "." || $0 == "-" })
        else { return nil }
        return host
    }
}

/// 网站图标：先显示域名首字母的圆形图标，下载到真图标就换掉。
struct FaviconView: View {
    let host: String?
    var size: CGFloat = 16

    @State private var store = FaviconStore.shared

    var body: some View {
        Group {
            if let host, let image = store.images[host] {
                Image(uiImage: image)
                    .resizable()
                    .interpolation(.high)
                    .scaledToFit()
                    .clipShape(RoundedRectangle(cornerRadius: size * 0.22, style: .continuous))
            } else {
                Text(initial)
                    .font(.system(size: size * 0.6, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: size, height: size)
                    .background(Circle().fill(color))
            }
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
        .task(id: host) {
            if let host { store.load(host) }
        }
    }

    /// 去掉 www. 之后的第一个字母。
    private var initial: String {
        let name = (host ?? "?").replacingOccurrences(of: "www.", with: "")
        return name.first.map { String($0).uppercased() } ?? "?"
    }

    /// 按域名固定选一个颜色，同一个网站每次都一样。
    private var color: Color {
        let colors: [Color] = [.blue, .orange, .green, .purple, .pink, .teal, .indigo, .brown]
        let sum = (host ?? "").unicodeScalars.reduce(0) { $0 &+ Int($1.value) }
        return colors[sum % colors.count]
    }
}

/// 网站图标的缓存（第八版）：App 直接从这个网站下载 /favicon.ico（没有时试 /apple-touch-icon.png），
/// 存在本机的缓存目录里。不用第三方图标服务，不把用户看过的网站告诉别人。
/// 下载不到的网站记下来，7 天内不再试。
@MainActor
@Observable
final class FaviconStore {
    static let shared = FaviconStore()

    private(set) var images: [String: UIImage] = [:]
    @ObservationIgnored private var loading: Set<String> = []
    @ObservationIgnored private var failed: Set<String> = []
    private let directory: URL = {
        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        let url = base.appending(path: "Favicons", directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }()

    private static let retryInterval: TimeInterval = 7 * 24 * 3600

    func load(_ host: String) {
        guard images[host] == nil, !loading.contains(host), !failed.contains(host) else { return }
        let file = directory.appending(path: host + ".img")
        if let data = try? Data(contentsOf: file), let image = UIImage(data: data) {
            images[host] = image
            return
        }
        let marker = directory.appending(path: host + ".none")
        if let attributes = try? FileManager.default.attributesOfItem(atPath: marker.path()),
           let date = attributes[.modificationDate] as? Date,
           Date.now.timeIntervalSince(date) < Self.retryInterval {
            failed.insert(host)
            return
        }
        loading.insert(host)
        Task {
            let data = await Self.download(host)
            loading.remove(host)
            if let data, let image = UIImage(data: data), image.size.width >= 8 {
                images[host] = image
                try? data.write(to: file, options: .atomic)
            } else {
                failed.insert(host)
                try? Data().write(to: marker, options: .atomic)
            }
        }
    }

    nonisolated private static func download(_ host: String) async -> Data? {
        for path in ["/favicon.ico", "/apple-touch-icon.png"] {
            guard let url = URL(string: "https://" + host + path) else { continue }
            var request = URLRequest(url: url, timeoutInterval: 8)
            request.setValue("image/*", forHTTPHeaderField: "Accept")
            guard let (data, response) = try? await URLSession.shared.data(for: request),
                  let http = response as? HTTPURLResponse, http.statusCode == 200,
                  !data.isEmpty, data.count < 300_000,
                  !(http.mimeType ?? "").hasPrefix("text/")
            else { continue }
            return data
        }
        return nil
    }
}
