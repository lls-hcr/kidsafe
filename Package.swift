// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "KidSafe",
    defaultLocalization: "fr",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "KidSafeCore", targets: ["KidSafeCore"]),
        .executable(name: "kidsafe-blocklist", targets: ["kidsafe-blocklist"]),
        .executable(name: "KidSafe", targets: ["KidSafeApp"]),
    ],
    targets: [
        .target(name: "KidSafeCore", resources: [.process("Resources")]),
        .executableTarget(name: "kidsafe-blocklist", dependencies: ["KidSafeCore"]),
        .executableTarget(name: "KidSafeApp", dependencies: ["KidSafeCore"]),
        .testTarget(name: "KidSafeCoreTests", dependencies: ["KidSafeCore"]),
    ]
)
