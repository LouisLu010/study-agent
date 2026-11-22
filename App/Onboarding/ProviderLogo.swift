import StudyKit
import SwiftUI

/// 服务商的官方图标（第八版），放在品牌色淡底的圆角方块里。
/// 图标是单色矢量图，按品牌色上色，深色模式下自动换成浅色的版本（OpenAI 用正文颜色）。
/// "其他"和对不上预设的服务商用系统图标。图标来自 Lobe Icons（MIT），商标归各自公司所有。
struct ProviderLogo: View {
    /// 预设的 id（`ProviderPreset.id`）。nil 表示对不上任何预设。
    let presetID: String?
    var size: CGFloat = 40

    var body: some View {
        let brand = ProviderBrand(presetID: presetID)
        ZStack {
            RoundedRectangle(cornerRadius: min(Theme.cardRadius, size * 0.3), style: .continuous)
                .fill(brand.color.opacity(0.12))
            if let asset = brand.asset {
                Image(asset)
                    .renderingMode(.template)
                    .resizable()
                    .scaledToFit()
                    .foregroundStyle(brand.color)
                    .padding(size * 0.2)
            } else {
                Image(systemName: brand.symbol)
                    .font(.system(size: size * 0.42, weight: .semibold))
                    .foregroundStyle(brand.color)
            }
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}

extension ProviderLogo {
    /// 按协议和地址的域名对应预设，设置里手动建的服务商也能显示图标。
    init(provider: Provider, size: CGFloat = 40) {
        self.init(presetID: ProviderPreset.matching(kind: provider.kind, baseURL: provider.baseURL)?.id, size: size)
    }
}

/// 各家服务商的图标和品牌色。
private struct ProviderBrand {
    let asset: String?
    let symbol: String
    let color: Color

    init(presetID: String?) {
        switch presetID {
        case "deepseek":
            asset = "Logo-deepseek"; color = Color(red: 0.302, green: 0.420, blue: 0.996)
        case "openai":
            asset = "Logo-openai"; color = .primary
        case "anthropic":
            asset = "Logo-anthropic"; color = Color(red: 0.851, green: 0.467, blue: 0.341)
        case "gemini":
            asset = "Logo-gemini"; color = Color(red: 0.192, green: 0.525, blue: 1.0)
        case "openrouter":
            asset = "Logo-openrouter"; color = Color(red: 0.392, green: 0.404, blue: 0.949)
        case "custom":
            asset = nil; color = .accentColor
        default:
            asset = nil; color = .secondary
        }
        symbol = presetID == "custom" ? "ellipsis" : "server.rack"
    }
}
