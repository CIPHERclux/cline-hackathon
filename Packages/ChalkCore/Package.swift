// swift-tools-version: 6.2
// ChalkCore: pure, headless-testable logic for the demo (D08). No AppKit, no I/O.
import PackageDescription

let package = Package(
    name: "ChalkCore",
    platforms: [.macOS(.v26)],
    products: [
        .library(name: "ChalkCore", targets: ["ChalkCore"]),
        // Grounding harness helper (§6.8): the app's own candidate code, run on golden screenshots.
        .executable(name: "grounding-marks", targets: ["GroundingMarks"]),
    ],
    targets: [
        .target(name: "ChalkCore"),
        .executableTarget(name: "GroundingMarks", dependencies: ["ChalkCore"]),
        .testTarget(name: "ChalkCoreTests", dependencies: ["ChalkCore"]),
    ]
)
