// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "PavlakUnifiedCore",
    platforms: [
        .macOS(.v13),
        .iOS(.v16)
    ],
    products: [
        .library(name: "PavlakCore", targets: ["PavlakCore"])
    ],
    targets: [
        .target(name: "PavlakCore"),
        .testTarget(name: "PavlakCoreTests", dependencies: ["PavlakCore"])
    ]
)
