// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "dusk",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "dusk", targets: ["dusk"]),
    ],
    targets: [
        .target(
            name: "DuskCore",
            linkerSettings: [.linkedFramework("IOKit"), .linkedFramework("CoreGraphics")]
        ),
        .executableTarget(name: "dusk", dependencies: ["DuskCore"]),
        .testTarget(name: "DuskCoreTests", dependencies: ["DuskCore"]),
    ]
)
