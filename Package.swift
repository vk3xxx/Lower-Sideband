// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "SidebandSwift",
    platforms: [.macOS(.v14), .iOS(.v17)],
    products: [
        .library(name: "SidebandCore", targets: ["SidebandCore"]),
        .executable(name: "SidebandMac", targets: ["SidebandMac"])
    ],
    dependencies: [
        .package(url: "https://github.com/AndrewBarba/ed25519.git", from: "1.1.0")
    ],
    targets: [
        .target(name: "SidebandCore", dependencies: [.product(name: "Ed25519", package: "ed25519")]),
        .executableTarget(name: "SidebandMac", dependencies: ["SidebandCore"]),
        .testTarget(name: "SidebandCoreTests", dependencies: ["SidebandCore"])
    ]
)
