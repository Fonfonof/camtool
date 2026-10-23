// swift-tools-version: 6.0
// CamTool — macOS on Apple Silicon only.
import PackageDescription

let package = Package(
    name: "CamTool",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "CamToolKit", targets: ["CamToolKit"]),
        .executable(name: "camtool", targets: ["camtool"]),
        .executable(name: "CamToolApp", targets: ["CamToolApp"]),
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-argument-parser", from: "1.5.0"),
    ],
    targets: [
        .target(name: "CamToolKit"),
        .executableTarget(
            name: "camtool",
            dependencies: [
                "CamToolKit",
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
            ]
        ),
        .executableTarget(name: "CamToolApp", dependencies: ["CamToolKit"]),
        .testTarget(name: "CamToolKitTests", dependencies: ["CamToolKit"]),
    ]
)
