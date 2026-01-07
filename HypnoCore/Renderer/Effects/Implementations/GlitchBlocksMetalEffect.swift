//
//  GlitchBlocksMetalEffect.swift
//  Hypnograph
//
//  Destructive block glitch effect.
//  Blocks randomly freeze, shift, corrupt colors, or streak.
//  More aggressive than BlockFreeze, simpler than Datamosh.
//

import Foundation
import CoreImage
import CoreVideo
import Metal

/// GPU parameters - must match GlitchBlocksShader.metal
struct GlitchBlocksParamsGPU {
    var textureWidth: Int32
    var textureHeight: Int32
    var blockSize: Int32
    var glitchAmount: Float
    var corruption: Float
    var randomSeed: UInt32
    var frameSeed: UInt32
}

/// Destructive block glitch effect
final class GlitchBlocksMetalEffect: MetalEffect {

    // MARK: - Parameter Specs

    override class var parameterSpecs: [String: ParameterSpec] {
        [
            "blockSize": .int(default: 32, range: 8...128),
            "glitchAmount": .float(default: 0.3, range: 0...1),
            "corruption": .float(default: 0.5, range: 0...1)
        ]
    }

    // MARK: - Properties

    override var name: String { "Glitch Blocks" }
    override var requiredLookback: Int { 20 }
    override var shaderFunctionName: String { "glitchBlocksKernel" }

    var blockSize: Int
    var glitchAmount: Float
    var corruption: Float

    // Stable seed changes slowly
    private var stableSeed: UInt32 = 0
    private var seedCounter: Int = 0
    private var frameCounter: UInt32 = 0

    // MARK: - Init

    init(blockSize: Int, glitchAmount: Float, corruption: Float) {
        self.blockSize = max(8, min(128, blockSize))
        self.glitchAmount = max(0, min(1, glitchAmount))
        self.corruption = max(0, min(1, corruption))
        super.init()
        setupMetal()
    }

    required convenience init?(params: [String: AnyCodableValue]?) {
        let p = Params(params, specs: Self.parameterSpecs)
        self.init(blockSize: p.int("blockSize"), glitchAmount: p.float("glitchAmount"), corruption: p.float("corruption"))
    }

    // MARK: - Effect Protocol

    override func apply(to image: CIImage, context: inout RenderContext) -> CIImage {
        frameCounter &+= 1

        // Update stable seed every ~20 frames (pattern changes slowly)
        seedCounter += 1
        if seedCounter >= 20 {
            seedCounter = 0
            stableSeed = UInt32.random(in: 0..<UInt32.max)
        }

        guard context.frameBuffer.frameCount >= 5 else { return image }
        guard isMetalReady else { return image }

        let extent = image.extent
        let width = Int(extent.width)
        let height = Int(extent.height)
        guard width > 0, height > 0 else { return image }

        // Get history from ~8 frames ago
        let historyOffset = min(8, context.frameBuffer.frameCount - 1)
        guard let historyTexture = context.frameBuffer.texture(atHistoryOffset: historyOffset) else {
            return image
        }

        ensureBuffers(width: width, height: height, names: ["input", "output"])
        guard let inBuf = buffer(named: "input"),
              let currentTexture = texture(from: inBuf),
              let outputTexture = texture(from: buffer(named: "output")!) else {
            return image
        }

        render(image, to: inBuf)

        var gpuParams = GlitchBlocksParamsGPU(
            textureWidth: Int32(width),
            textureHeight: Int32(height),
            blockSize: Int32(blockSize),
            glitchAmount: glitchAmount,
            corruption: corruption,
            randomSeed: stableSeed,
            frameSeed: frameCounter
        )

        return runShader(outputBufferName: "output", fallback: image) { encoder in
            encoder.setTexture(currentTexture, index: 0)
            encoder.setTexture(historyTexture, index: 1)
            encoder.setTexture(outputTexture, index: 2)
            encoder.setBytes(&gpuParams, length: MemoryLayout<GlitchBlocksParamsGPU>.stride, index: 0)
        }
    }

    override func reset() {
        super.reset()
        frameCounter = 0
        stableSeed = 0
        seedCounter = 0
    }

    override func copy() -> Effect {
        GlitchBlocksMetalEffect(blockSize: blockSize, glitchAmount: glitchAmount, corruption: corruption)
    }
}
