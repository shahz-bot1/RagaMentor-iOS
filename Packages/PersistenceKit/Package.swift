// swift-tools-version: 5.9
import PackageDescription

// PersistenceKit — local package (PARITY-PLAN §3). Boundaries are compiler-enforced.
let package = Package(
    name: "PersistenceKit",
    platforms: [.iOS(.v17)],
    products: [.library(name: "PersistenceKit", targets: ["PersistenceKit"])],
    dependencies: [.package(path: "../RagaCore")],
    targets: [.target(name: "PersistenceKit", dependencies: ["RagaCore"])]
)
