// swift-tools-version: 5.9
import PackageDescription

// Tala — local package (PARITY-PLAN §3): Tala Studio, the tala
// wheel and click metronome. TalaSpec (data + math) lives in
// RagaCore; the click voice lives in AudioKit.
let package = Package(
    name: "Tala",
    platforms: [.iOS(.v17)],
    products: [.library(name: "Tala", targets: ["Tala"])],
    dependencies: [
        .package(path: "../RagaCore"),
        .package(path: "../AudioKit"),
        .package(path: "../DesignSystem"),
    ],
    targets: [.target(name: "Tala",
                      dependencies: ["RagaCore", "AudioKit", "DesignSystem"])]
)
