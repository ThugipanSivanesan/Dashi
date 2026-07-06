// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "Dashi",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "Dashi", targets: ["Dashi"]),
        .library(name: "DashiCore", targets: ["DashiCore"]),
    ],
    dependencies: [
        // Sparkle powers in-app auto-updates for the distributable build. Only the app target
        // links it; DashiCore and the tests stay dependency-free.
        .package(url: "https://github.com/sparkle-project/Sparkle", from: "2.6.0")
    ],
    targets: [
        .target(name: "DashiCore"),
        .executableTarget(
            name: "Dashi",
            dependencies: ["DashiCore", .product(name: "Sparkle", package: "Sparkle")]),
        .testTarget(name: "DashiCoreTests", dependencies: ["DashiCore"]),
    ]
)
