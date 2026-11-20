// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "iMarkDown",
    platforms: [.macOS("26.0")],
    products: [
        .executable(name: "iMarkDown", targets: ["iMarkDown"]),
        .executable(name: "MarkdownKitChecks", targets: ["MarkdownKitChecks"]),
        .library(name: "MarkdownKit", targets: ["MarkdownKit"])
    ],
    targets: [
        .target(
            name: "MarkdownKit",
            path: "Sources/MarkdownKit",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .executableTarget(
            name: "iMarkDown",
            dependencies: ["MarkdownKit"],
            path: "Sources/iMarkDown",
            resources: [.copy("Resources/Web")],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        // 本机只装了 Command Line Tools，XCTest / swift-testing 的运行器不可用，
        // 因此用可执行目标承载 MarkdownKit 的单元检查，`swift run MarkdownKitChecks`。
        .executableTarget(
            name: "MarkdownKitChecks",
            dependencies: ["MarkdownKit"],
            path: "Tests/MarkdownKitChecks",
            swiftSettings: [.swiftLanguageMode(.v5)]
        )
    ]
)
