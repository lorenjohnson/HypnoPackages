// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "HypnoPackages",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .library(name: "HypnoCore", targets: ["HypnoCore"]),
        .library(name: "HypnoUI", targets: ["HypnoUI"])
    ],
    targets: [
        .target(
            name: "HypnoCore",
            path: "HypnoCore",
            resources: [
                .process("Renderer/Effects/Library/effects-default.json"),
                .copy("Renderer/Effects/Library/BundledLUTs"),
                .copy("Renderer/Effects/RuntimeAssets"),
                .process("Renderer/Display/Passthrough.metal"),
                .process("Renderer/Display/YUVConversion.metal"),
                .process("Renderer/Transitions/Implementations/BlurTransition.metal"),
                .process("Renderer/Transitions/Implementations/CrossfadeTransition.metal"),
                .process("Renderer/Transitions/Implementations/SlideLeftTransition.metal"),
                .process("Renderer/Transitions/Implementations/SlideUpTransition.metal")
            ]
        ),
        .target(
            name: "HypnoUI",
            dependencies: ["HypnoCore"],
            path: "HypnoUI"
        ),
        .testTarget(
            name: "HypnoCoreTests",
            dependencies: ["HypnoCore"],
            path: "HypnoCoreTests"
        )
    ]
)
