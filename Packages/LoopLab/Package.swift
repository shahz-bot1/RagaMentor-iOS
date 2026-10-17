// swift-tools-version: 5.9
import PackageDescription

// LoopLab — local package (PARITY-PLAN §3). Boundaries are compiler-enforced.
let package = Package(
    name: "LoopLab",
    platforms: [.iOS(.v17)],
    products: [.library(name: "LoopLab", targets: ["LoopLab"])],
    dependencies: [
        .package(path: "../RagaCore"),
        .package(path: "../AudioKit"),
        .package(path: "../PersistenceKit"),
        .package(path: "../DesignSystem")
    ],
    targets: [.target(name: "LoopLab", dependencies: ["RagaCore", "AudioKit", "PersistenceKit", "DesignSystem"])]
)
