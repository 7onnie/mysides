// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "mysides",
    platforms: [.macOS(.v13)],
    targets: [
        .executableTarget(
            name: "mysides",
            path: "Sources/mysides"
        )
    ]
)
