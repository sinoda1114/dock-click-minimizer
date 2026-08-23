// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "dock-click-minimizer",
    platforms: [
        .macOS(.v14)
    ],
    targets: [
        .target(
            name: "DockClickMinimizerCore"
        ),
        .executableTarget(
            name: "dock-click-minimizer",
            dependencies: ["DockClickMinimizerCore"]
        ),
        .testTarget(
            name: "DockClickMinimizerCoreTests",
            dependencies: ["DockClickMinimizerCore"]
        )
    ]
)
