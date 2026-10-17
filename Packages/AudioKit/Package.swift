// swift-tools-version: 5.9
import PackageDescription

// AudioKit — local package (PARITY-PLAN §3). Boundaries are compiler-enforced.
let package = Package(
    name: "AudioKit",
    platforms: [.iOS(.v17)],
    products: [.library(name: "AudioKit", targets: ["AudioKit"])],
    dependencies: [
        .package(path: "../RagaCore")
    ],
    targets: [.target(name: "AudioKit", dependencies: ["RagaCore"])]
)
