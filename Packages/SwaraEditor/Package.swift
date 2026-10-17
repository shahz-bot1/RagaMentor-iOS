// swift-tools-version: 5.9
import PackageDescription

// SwaraEditor — local package (PARITY-PLAN §3). The ONE swara phrase
// editor, shared by LoopLab loop phrases (P1) and Compose (P2).
let package = Package(
    name: "SwaraEditor",
    platforms: [.iOS(.v17)],
    products: [.library(name: "SwaraEditor", targets: ["SwaraEditor"])],
    dependencies: [
        .package(path: "../RagaCore"),
        .package(path: "../AudioKit"),
        .package(path: "../DesignSystem"),
    ],
    targets: [.target(name: "SwaraEditor",
                      dependencies: ["RagaCore", "AudioKit", "DesignSystem"])]
)
