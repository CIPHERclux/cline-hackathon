// swift-tools-version: 6.2
// Use-case simulator for guided walkthroughs (D86): drives ChalkCore's GuideCoordinator against
// scripted screens (Eval/usecases/*.json) with a simulated user, through the real tutor-engine.
// Never launches Chalk.app; the free `dev` profile by default.
import PackageDescription

let package = Package(
    name: "GuideSim",
    platforms: [.macOS(.v26)],
    dependencies: [.package(path: "../../Packages/ChalkCore")],
    targets: [
        .executableTarget(
            name: "GuideSim", dependencies: [.product(name: "ChalkCore", package: "ChalkCore")])
    ]
)
