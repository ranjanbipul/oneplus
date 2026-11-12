// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "CallBridgeMac",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "CallBridgeMac",
            path: "Sources/CallBridgeMac"
        ),
    ]
)
