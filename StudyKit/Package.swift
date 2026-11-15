// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "StudyKit",
    platforms: [.iOS(.v18), .macOS(.v15)],
    products: [
        .library(name: "StudyKit", targets: ["StudyKit"]),
    ],
    targets: [
        .target(name: "StudyKit", resources: [.copy("Prompts")]),
        .testTarget(name: "StudyKitTests", dependencies: ["StudyKit"]),
    ]
)
