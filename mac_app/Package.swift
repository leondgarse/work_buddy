// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "ReqBuddy",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "ReqBuddy", targets: ["ReqBuddy"]),
        .executable(name: "reqcli", targets: ["reqcli"]),
    ],
    targets: [
        .target(name: "ReqCore"),
        .testTarget(name: "ReqCoreTests", dependencies: ["ReqCore"]),
        .executableTarget(name: "ReqBuddy", dependencies: ["ReqCore"]),
        .testTarget(name: "ReqBuddyTests", dependencies: ["ReqBuddy", "ReqCore"]),
        .executableTarget(name: "reqcli", dependencies: ["ReqCore"]),
    ]
)
