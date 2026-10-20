// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "Harbour",
    platforms: [.macOS(.v26)],
    products: [
        .executable(name: "harbour", targets: ["harbour"]),
        .executable(name: "HarbourApp", targets: ["HarbourApp"]),
    ],
    targets: [
        .target(name: "HarbourCore"),
        .executableTarget(name: "harbour", dependencies: ["HarbourCore"]),
        .executableTarget(name: "HarbourApp", dependencies: ["HarbourCore"]),
        .testTarget(name: "HarbourCoreTests", dependencies: ["HarbourCore"]),
    ]
)
