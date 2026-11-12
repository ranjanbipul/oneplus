// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "CallBridge",
    platforms: [.macOS(.v14), .iOS(.v17)],
    products: [
        .library(name: "CallBridgeCore", targets: ["CallBridgeCore"]),
        .executable(name: "CallBridgeMac", targets: ["CallBridgeMac"]),
    ],
    targets: [
        // Protocol, gateway link and call audio, shared by the Mac app, the iPhone app and
        // the iPhone's push extension.
        .target(name: "CallBridgeCore"),
        .executableTarget(name: "CallBridgeMac", dependencies: ["CallBridgeCore"]),
    ]
)
