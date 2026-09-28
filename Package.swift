// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "ScreenshotRenamer",
    platforms: [.macOS(.v13)],
    products: [
        .library(name: "RenamerCore", targets: ["RenamerCore"]),
        .executable(name: "ScreenshotRenamer", targets: ["ScreenshotRenamer"])
    ],
    dependencies: [
        .package(url: "https://github.com/sparkle-project/Sparkle", exact: "2.10.0")
    ],
    targets: [
        .target(name: "RenamerCore"),
        .executableTarget(name: "ScreenshotRenamer", dependencies: [
            "RenamerCore", .product(name: "Sparkle", package: "Sparkle")
        ], linkerSettings: [.unsafeFlags(["-Xlinker", "-rpath", "-Xlinker", "@executable_path/../Frameworks"])]),
        .testTarget(name: "RenamerCoreTests", dependencies: ["RenamerCore"])
    ],
    swiftLanguageModes: [.v5]
)
