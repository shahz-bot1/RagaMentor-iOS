// swift-tools-version: 5.9
import PackageDescription

// Varisai — local package (PARITY-PLAN §3): Varisai Studio, the
// structured practice player (7 lessons, 50 patterns, all
// Mayamalavagowla). Lesson data is generated from the mock repo,
// the notation source of truth.
let package = Package(
    name: "Varisai",
    platforms: [.iOS(.v17)],
    products: [.library(name: "Varisai", targets: ["Varisai"])],
    dependencies: [
        .package(path: "../RagaCore"),
        .package(path: "../AudioKit"),
        .package(path: "../DesignSystem"),
    ],
    targets: [.target(name: "Varisai",
                      dependencies: ["RagaCore", "AudioKit", "DesignSystem"])]
)
