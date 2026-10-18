// swift-tools-version: 5.9
import PackageDescription

// Composer — local package (PARITY-PLAN §3): Compose Studio. A
// feature module; it depends on the shared services and the ONE
// SwaraEditor, never on another feature module.
let package = Package(
    name: "Composer",
    platforms: [.iOS(.v17)],
    products: [.library(name: "Composer", targets: ["Composer"])],
    dependencies: [
        .package(path: "../RagaCore"),
        .package(path: "../AudioKit"),
        .package(path: "../PersistenceKit"),
        .package(path: "../DesignSystem"),
        .package(path: "../SwaraEditor"),
        .package(path: "../RagaBrowser"),
    ],
    targets: [.target(name: "Composer",
                      dependencies: ["RagaCore", "AudioKit", "PersistenceKit",
                                     "DesignSystem", "SwaraEditor", "RagaBrowser"])]
)
