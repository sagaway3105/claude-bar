// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "ClaudeBar",
    // システム環境設定の言語に追従する（未対応言語は英語にフォールバック）
    defaultLocalization: "en",
    platforms: [.macOS("14.0")],
    dependencies: [
        .package(url: "https://github.com/sparkle-project/Sparkle", from: "2.6.0"),
    ],
    targets: [
        .executableTarget(
            name: "ClaudeBar",
            dependencies: [
                .product(name: "Sparkle", package: "Sparkle"),
            ],
            path: "Sources/ClaudeBar",
            resources: [.process("Resources")],
            swiftSettings: [.swiftLanguageMode(.v5)],
            // 配布 .app では Sparkle.framework を Contents/Frameworks に同梱するため、
            // 実行ファイルからそこを探せるように rpath を通す
            linkerSettings: [
                .unsafeFlags(["-Xlinker", "-rpath", "-Xlinker", "@executable_path/../Frameworks"])
            ]
        ),
        .testTarget(
            name: "ClaudeBarTests",
            dependencies: ["ClaudeBar"],
            path: "Tests/ClaudeBarTests",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
    ]
)
