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
                .process("Renderer/Effects/Library/effects-default-old.json"),
                .process("Renderer/Display/Passthrough.metal"),
                .process("Renderer/Display/YUVConversion.metal"),
                .process("Renderer/Effects/Implementations/BasicShader.metal"),
                .process("Renderer/Effects/Implementations/BlockFreezeShader.metal"),
                .process("Renderer/Effects/Implementations/ColorEchoShader.metal"),
                .process("Renderer/Effects/Implementations/DatamoshShader.metal"),
                .process("Renderer/Effects/Implementations/GaussianBlurShader.metal"),
                .process("Renderer/Effects/Implementations/GlitchBlocksShader.metal"),
                .process("Renderer/Effects/Implementations/IFrameShader.metal"),
                .process("Renderer/Effects/Implementations/PixelDriftShader.metal"),
                .process("Renderer/Effects/Implementations/PixelateShader.metal"),
                .process("Renderer/Effects/Implementations/TimeShuffleShader.metal"),
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
