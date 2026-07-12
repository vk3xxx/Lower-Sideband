// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "SidebandSwift",
    platforms: [.macOS(.v14), .iOS(.v17)],
    products: [
        .library(name: "SidebandCore", targets: ["SidebandCore"]),
        .executable(name: "SidebandMac", targets: ["SidebandMac"])
    ],
    targets: [
        .target(name: "SidebandCore"),
        .executableTarget(name: "SidebandMac", dependencies: ["SidebandCore"]),
        .testTarget(name: "SidebandCoreTests", dependencies: ["SidebandCore"])
    ]
)
