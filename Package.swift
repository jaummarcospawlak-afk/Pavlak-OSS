// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Pavlek",
    platforms: [.macOS(.v14), .iOS(.v17)],
    products: [
        .executable(name: "Pavlek", targets: ["Pavlek"]),
        .executable(name: "PavlakMCPBridge", targets: ["PavlakMCPBridge"])
    ],
    targets: [
        .executableTarget(name: "Pavlek"),
        .executableTarget(name: "PavlakMCPBridge"),
        .testTarget(name: "PavlekTests", dependencies: ["Pavlek"])
    ]
)
