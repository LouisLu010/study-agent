import SwiftUI
import UIKit

/// 全 App 共用的样式（第六版）：主题色、圆角、间距。新代码只用这里的值，不再各写各的。
enum Theme {
    /// 卡片的圆角。
    static let cardRadius: CGFloat = 12
    /// 输入框和消息气泡的圆角。筛选标签一类的小块用胶囊形。
    static let fieldRadius: CGFloat = 20

    /// 间距只用这几档：4、8、12、16、24。
    enum Spacing {
        static let xs: CGFloat = 4
        static let s: CGFloat = 8
        static let m: CGFloat = 12
        static let l: CGFloat = 16
        static let xl: CGFloat = 24
    }

    /// 答对、完成。取自图标里的绿点，浅色模式加深一些，保证在白底上看得清。
    /// 深色 #4ADE80，浅色 #16A34A；渲染器的 `--green` 用同样的值。
    static let success = Color(uiColor: UIColor { traits in
        traits.userInterfaceStyle == .dark
            ? UIColor(red: 0.290, green: 0.871, blue: 0.502, alpha: 1)
            : UIColor(red: 0.086, green: 0.639, blue: 0.290, alpha: 1)
    })
}

extension View {
    /// 卡片背景：次级背景色，12 圆角。
    func cardBackground() -> some View {
        background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: Theme.cardRadius, style: .continuous))
    }

    /// 玻璃效果，只用在输入框底栏、引导页底部按钮和"回到底部"按钮上。
    /// iOS 26 用系统的 Liquid Glass；iOS 18 用材质背景加一圈很淡的描边。
    @ViewBuilder
    func glassSurface<S: Shape>(in shape: S, interactive: Bool = false) -> some View {
        if #available(iOS 26.0, *) {
            glassEffect(interactive ? .regular.interactive() : .regular, in: shape)
        } else {
            background(.regularMaterial, in: shape)
                .overlay(shape.stroke(Color.primary.opacity(0.1), lineWidth: 0.5))
        }
    }
}

extension View {
    /// 引导页底部的主按钮：iOS 26 用带主题色的玻璃按钮，iOS 18 用实心的主题色按钮（材质背景在纯色页面上看不出按钮）。
    @ViewBuilder
    func primaryButtonStyle() -> some View {
        if #available(iOS 26.0, *) {
            buttonStyle(.glassProminent)
        } else {
            buttonStyle(.borderedProminent)
        }
    }
}

/// 小球表示的模型活动（见 GLOSSARY「小球」）。普通加载（PDF 转图片、拉模型列表）不用小球，仍用系统转圈。
enum OrbActivity {
    /// 等模型回复、验证 API Key、整理资料这类"模型在干活"。
    case working
    /// 思考。
    case reasoning
    /// 联网搜索。
    case searching
    /// 汇编在后台收集。
    case background
    /// 重新获取一道没取到的原题。
    case retrying
    /// 引导页和空页面上的主图，不代表任何活动。
    case idle

    fileprivate var state: OrbState {
        switch self {
        case .working: .working
        case .reasoning: .reasoning
        case .searching: .searching
        case .background: .background
        case .retrying: .retrying
        case .idle: .idle
        }
    }

    /// 旁白读的名字。主图只是装饰，不读。
    fileprivate var label: String? {
        switch self {
        case .working: "正在生成"
        case .reasoning: "正在思考"
        case .searching: "正在搜索"
        case .background: "正在后台收集"
        case .retrying: "正在重新获取"
        case .idle: nil
        }
    }
}

/// 用主题色画的小球。打开"减弱动态效果"后停住不动。
struct ActivityOrb: View {
    let activity: OrbActivity
    var size: CGFloat = 20

    var body: some View {
        Orb(state: activity.state, size: size, label: activity.label)
            .foregroundStyle(.tint)
    }
}
