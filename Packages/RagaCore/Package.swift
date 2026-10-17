// swift-tools-version: 5.9
import PackageDescription

// RagaCore — local package (PARITY-PLAN §3). Boundaries are compiler-enforced.
let package = Package(
    name: "RagaCore",
    platforms: [.iOS(.v17)],
    products: [.library(name: "RagaCore", targets: ["RagaCore"])],
    targets: [.target(name: "RagaCore")]
)
