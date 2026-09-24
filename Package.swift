// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "NotchShelf",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "NotchShelf",
            path: "Sources/NotchShelf",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .testTarget(
            name: "NotchShelfTests",
            dependencies: ["NotchShelf"],
            path: "Tests/NotchShelfTests",
            swiftSettings: [.swiftLanguageMode(.v5)]
        )
    ]
)
