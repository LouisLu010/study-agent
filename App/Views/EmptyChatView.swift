import SwiftUI

/// 还没发消息的会话：小球、一句提示和 4 个随机的示例问题。点示例只填进输入框，不直接发送。
struct EmptyChatView: View {
    let onPick: (String) -> Void

    @State private var examples = ExampleQuestions.random(4)

    var body: some View {
        ScrollView {
            VStack(spacing: Theme.Spacing.xl) {
                Spacer(minLength: Theme.Spacing.xl)
                ActivityOrb(activity: .idle, size: 88)
                VStack(spacing: Theme.Spacing.s) {
                    Text("问点什么吧")
                        .font(.title3.bold())
                    Text("可以拍题、传 PDF 或手写。回答里的坐标图、测验和模拟都能直接动手试。")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
                VStack(spacing: Theme.Spacing.s) {
                    ForEach(examples) { example in
                        Button {
                            onPick(example.text)
                        } label: {
                            HStack(spacing: Theme.Spacing.m) {
                                Text(example.subject)
                                    .font(.caption.bold())
                                    .foregroundStyle(.tint)
                                    .padding(.horizontal, Theme.Spacing.s)
                                    .padding(.vertical, 2)
                                    .background(Color.accentColor.opacity(0.12), in: Capsule())
                                Text(example.text)
                                    .font(.callout)
                                    .foregroundStyle(.primary)
                                    .multilineTextAlignment(.leading)
                                Spacer(minLength: 0)
                            }
                            .padding(Theme.Spacing.m)
                            .cardBackground()
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityHint("填进输入框")
                    }
                }
            }
            .padding(.horizontal, Theme.Spacing.l)
            .frame(maxWidth: 560)
            .frame(maxWidth: .infinity)
        }
        .scrollBounceBehavior(.basedOnSize)
    }
}

/// 空会话里的示例问题，覆盖数学、物理、化学、生物、英语。
enum ExampleQuestions {
    struct Example: Identifiable {
        let subject: String
        let text: String
        var id: String { text }
    }

    static let all: [Example] = [
        Example(subject: "数学", text: "求 f(x) = x³ − 3x 的极值，并画出函数图像"),
        Example(subject: "数学", text: "等差数列前 n 项和公式是怎么推出来的？"),
        Example(subject: "数学", text: "用几何图说明：同弧所对的圆周角相等"),
        Example(subject: "物理", text: "平抛运动的轨迹为什么是抛物线？演示一下"),
        Example(subject: "物理", text: "带电粒子在匀强磁场里为什么做匀速圆周运动？"),
        Example(subject: "物理", text: "出 3 道牛顿第二定律的题考考我"),
        Example(subject: "化学", text: "配平：KMnO₄ + HCl → KCl + MnCl₂ + Cl₂ + H₂O"),
        Example(subject: "化学", text: "勒夏特列原理是什么？用化学平衡演示一下"),
        Example(subject: "生物", text: "有丝分裂和减数分裂有哪些区别？"),
        Example(subject: "生物", text: "光合作用的光反应和暗反应分别发生了什么？"),
        Example(subject: "英语", text: "虚拟语气的三种情况，各给一个例句"),
        Example(subject: "英语", text: "出 5 道定语从句的选择题考考我"),
    ]

    static func random(_ count: Int) -> [Example] {
        Array(all.shuffled().prefix(count))
    }
}
