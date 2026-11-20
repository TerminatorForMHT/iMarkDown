// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "iMarkDown",
    platforms: [.macOS("26.0")],
    products: [
        .executable(name: "iMarkDown", targets: ["iMarkDown"]),
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
        )
    ]
)
