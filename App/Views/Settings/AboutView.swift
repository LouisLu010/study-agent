import SwiftUI

/// 版本号和用到的开源组件。
struct AboutView: View {
    private struct Credit: Identifiable {
        let name: String
        let license: String
        let url: String
        var id: String { name }
    }

    private let credits: [Credit] = [
        Credit(name: "Thinking Orbs", license: "MIT", url: "https://github.com/yogesharc/thinking-orbs"),
        Credit(name: "KaTeX（含 mhchem）", license: "MIT", url: "https://github.com/KaTeX/KaTeX"),
        Credit(name: "markdown-it", license: "MIT", url: "https://github.com/markdown-it/markdown-it"),
        Credit(name: "highlight.js", license: "BSD-3-Clause", url: "https://github.com/highlightjs/highlight.js"),
        Credit(name: "JSXGraph", license: "MIT", url: "https://github.com/jsxgraph/jsxgraph"),
        Credit(name: "Chart.js", license: "MIT", url: "https://github.com/chartjs/Chart.js"),
    ]

    private var version: String {
        let info = Bundle.main.infoDictionary
        let short = info?["CFBundleShortVersionString"] as? String ?? "?"
        let build = info?["CFBundleVersion"] as? String ?? "?"
        return "\(short)（\(build)）"
    }

    var body: some View {
        List {
            Section {
                VStack(spacing: Theme.Spacing.m) {
                    ActivityOrb(activity: .idle, size: 64)
                    Text("格物")
                        .font(.headline)
                    Text("版本 \(version)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, Theme.Spacing.s)
            }

            Section {
                ForEach(credits) { credit in
                    if let url = URL(string: credit.url) {
                        Link(destination: url) {
                            LabeledContent(credit.name, value: credit.license)
                        }
                    }
                }
            } header: {
                Text("开源组件")
            } footer: {
                Text("感谢这些项目。许可证全文随源码放在仓库的 App/Vendor 和 Renderer/vendor 目录里。")
            }
        }
        .navigationTitle("关于")
        .navigationBarTitleDisplayMode(.inline)
    }
}
