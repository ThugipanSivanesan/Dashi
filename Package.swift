// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "Dashi",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "Dashi", targets: ["Dashi"]),
        .library(name: "DashiCore", targets: ["DashiCore"]),
    ],
    targets: [
        .target(name: "DashiCore"),
        .executableTarget(name: "Dashi", dependencies: ["DashiCore"]),
        .testTarget(name: "DashiCoreTests", dependencies: ["DashiCore"]),
    ]
)
