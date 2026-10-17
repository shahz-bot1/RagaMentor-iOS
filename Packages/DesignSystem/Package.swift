// swift-tools-version: 5.9
import PackageDescription

// DesignSystem — local package (PARITY-PLAN §3). Boundaries are compiler-enforced.
let package = Package(
    name: "DesignSystem",
    platforms: [.iOS(.v17)],
    products: [.library(name: "DesignSystem", targets: ["DesignSystem"])],
    targets: [.target(name: "DesignSystem")]
)
