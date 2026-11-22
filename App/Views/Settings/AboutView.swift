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
        Credit(name: "Lobe Icons（服务商图标）", license: "MIT", url: "https://github.com/lobehub/lobe-icons"),
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
                    // 自签工具可能改掉 Bundle ID，后台任务会因此失效；排查问题时用。
                    Text(Bundle.main.bundleIdentifier ?? "")
                        .font(.caption2.monospaced())
                        .foregroundStyle(.tertiary)
                        .textSelection(.enabled)
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
                Text("感谢这些项目。许可证全文随源码放在仓库的 App/Vendor 和 Renderer/vendor 目录里。\n\nDeepSeek、OpenAI、Anthropic、Gemini、OpenRouter 的名称和图标是各自公司的商标，App 只用它们标明服务商，和这些公司没有关联。")
            }
        }
        .navigationTitle("关于")
        .navigationBarTitleDisplayMode(.inline)
    }
}
