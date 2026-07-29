// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "SidebandSwift",
    platforms: [.macOS(.v14), .iOS(.v17)],
    products: [
        .library(name: "ReticulumKit", targets: ["ReticulumKit"]),
        .library(name: "SidebandCore", targets: ["SidebandCore"]),
        .executable(name: "SidebandMac", targets: ["SidebandMac"])
    ],
    dependencies: [
        .package(url: "https://github.com/AndrewBarba/ed25519.git", from: "1.1.0")
    ],
    targets: [
        .binaryTarget(name: "CCodec2", path: "Vendor/Codec2.xcframework"),
        .target(
            name: "ReticulumKit",
            dependencies: [.product(name: "Ed25519", package: "ed25519")],
            linkerSettings: [.linkedLibrary("bz2")]
        ),
        .target(
            name: "SidebandCore",
            dependencies: ["ReticulumKit", "CCodec2", .product(name: "Ed25519", package: "ed25519")],
            linkerSettings: [.linkedLibrary("sqlite3"), .linkedLibrary("bz2")]
        ),
        .executableTarget(name: "SidebandMac", dependencies: ["SidebandCore"]),
        .testTarget(name: "SidebandCoreTests", dependencies: ["SidebandCore"]),
        .testTarget(name: "ReticulumKitTests", dependencies: ["ReticulumKit"])
    ]
)
