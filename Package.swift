// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "ScreenshotRenamer",
    platforms: [.macOS(.v13)],
    products: [
        .library(name: "RenamerCore", targets: ["RenamerCore"]),
        .executable(name: "ScreenshotRenamer", targets: ["ScreenshotRenamer"])
    ],
    targets: [
        .target(name: "RenamerCore"),
        .executableTarget(name: "ScreenshotRenamer", dependencies: ["RenamerCore"]),
        .testTarget(name: "RenamerCoreTests", dependencies: ["RenamerCore"])
    ],
    swiftLanguageModes: [.v5]
)
