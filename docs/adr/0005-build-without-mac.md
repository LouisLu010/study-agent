# 没有 Mac：用 XcodeGen + GitHub Actions 编译，侧载未签名 ipa

开发者没有 Mac，也没有付费 Apple Developer 账号。所以仓库里不提交 `.xcodeproj`，只提交 XcodeGen 的 `project.yml`，由 GitHub Actions 的 macOS 机器生成工程、运行 `StudyKit` 的测试、编译 App，并打包一个未签名的 `.ipa` 作为 artifact。安装时在 Windows 上用 Sideloadly 或 AltStore 配合免费 Apple ID 签名后侧载，每 7 天需要重签一次，App 只能自己用。仓库是公开的，GitHub Actions 的 macOS 机器不收费。

## Consequences

本地无法直接运行或调试 App，每次验证都要等 CI 跑完。以后有了 Mac 或付费账号，可以改用 Xcode 直接安装或 TestFlight 分发，同时开启 iCloud 同步（见 ADR-0004）。
