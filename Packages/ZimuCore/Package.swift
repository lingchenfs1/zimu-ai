// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "ZimuCore",
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "ZimuCore", targets: ["ZimuCore"]),
    ],
    targets: [
        .target(name: "ZimuCore"),
        .testTarget(name: "ZimuCoreTests", dependencies: ["ZimuCore"]),
    ]
)
