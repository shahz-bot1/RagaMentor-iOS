// swift-tools-version: 5.9
import PackageDescription

// RagaBrowser — local package (PARITY-PLAN §3): the 87-raga
// browser (Search / Favourites / Melakartas / Hindustani), the raga
// detail with its display piano and Listen playback, and the live
// RagaPicker the editors present in pick mode (P3).
let package = Package(
    name: "RagaBrowser",
    platforms: [.iOS(.v17)],
    products: [.library(name: "RagaBrowser", targets: ["RagaBrowser"])],
    dependencies: [
        .package(path: "../RagaCore"),
        .package(path: "../AudioKit"),
        .package(path: "../DesignSystem"),
    ],
    targets: [.target(name: "RagaBrowser",
                      dependencies: ["RagaCore", "AudioKit", "DesignSystem"])]
)
