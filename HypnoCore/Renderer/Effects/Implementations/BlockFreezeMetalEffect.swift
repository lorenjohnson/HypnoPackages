//
//  BlockFreezeMetalEffect.swift
//  Hypnograph
//
//  Simple block-based freeze effect.
//  Blocks randomly freeze while others update, creating temporal mosaic.
//  Much simpler than full Datamosh - just 3 parameters.
//

import Foundation
import CoreImage
import CoreVideo
import Metal

/// GPU parameters - must match BlockFreezeShader.metal
struct BlockFreezeParamsGPU {
    var textureWidth: Int32
    var textureHeight: Int32
    var blockSize: Int32
    var freezeChance: Float
    var streakChance: Float
    var randomSeed: UInt32
}

/// Simple block freeze effect - blocks randomly freeze in place
final class BlockFreezeMetalEffect: MetalEffect {

    // MARK: - Parameter Specs

    override class var parameterSpecs: [String: ParameterSpec] {
        [
            "blockSize": .int(default: 24, range: 8...128),
            "freezeAmount": .float(default: 0.4, range: 0...1),
            "streakAmount": .float(default: 0.3, range: 0...1)
        ]
    }

    // MARK: - Properties

    override var name: String { "Block Freeze" }
    override var requiredLookback: Int { 30 }
    override var shaderFunctionName: String { "blockFreezeKernel" }

    var blockSize: Int
    var freezeAmount: Float
    var streakAmount: Float

    // Seed changes slowly for stable blocks
    private var currentSeed: UInt32 = 0
    private var seedChangeCounter: Int = 0

    // MARK: - Init

    init(blockSize: Int, freezeAmount: Float, streakAmount: Float) {
        self.blockSize = max(8, min(128, blockSize))
        self.freezeAmount = max(0, min(1, freezeAmount))
        self.streakAmount = max(0, min(1, streakAmount))
        super.init()
        setupMetal()
    }

    required convenience init?(params: [String: AnyCodableValue]?) {
        let p = Params(params, specs: Self.parameterSpecs)
        self.init(blockSize: p.int("blockSize"), freezeAmount: p.float("freezeAmount"), streakAmount: p.float("streakAmount"))
    }

    // MARK: - Effect Protocol

    override func apply(to image: CIImage, context: inout RenderContext) -> CIImage {
        // Update seed slowly (every ~15 frames) for stable freeze pattern
        seedChangeCounter += 1
        if seedChangeCounter >= 15 {
            seedChangeCounter = 0
            currentSeed = UInt32.random(in: 0..<UInt32.max)
        }

        // Need some history
        guard context.frameBuffer.frameCount >= 5 else { return image }
        guard isMetalReady else { return image }

        let extent = image.extent
        let width = Int(extent.width)
        let height = Int(extent.height)
        guard width > 0, height > 0 else { return image }

        // Get history texture (from ~10 frames ago for visible freeze)
        let historyOffset = min(10, context.frameBuffer.frameCount - 1)
        guard let historyTexture = context.frameBuffer.texture(atHistoryOffset: historyOffset) else {
            return image
        }

        // Prepare buffers
        ensureBuffers(width: width, height: height, names: ["input", "output"])
        guard let inBuf = buffer(named: "input"),
              let currentTexture = texture(from: inBuf),
              let outputTexture = texture(from: buffer(named: "output")!) else {
            return image
        }

        // Render current to input buffer
        render(image, to: inBuf)

        // Setup params
        var gpuParams = BlockFreezeParamsGPU(
            textureWidth: Int32(width),
            textureHeight: Int32(height),
            blockSize: Int32(blockSize),
            freezeChance: freezeAmount,
            streakChance: streakAmount,
            randomSeed: currentSeed
        )

        return runShader(outputBufferName: "output", fallback: image) { encoder in
            encoder.setTexture(currentTexture, index: 0)
            encoder.setTexture(historyTexture, index: 1)
            encoder.setTexture(outputTexture, index: 2)
            encoder.setBytes(&gpuParams, length: MemoryLayout<BlockFreezeParamsGPU>.stride, index: 0)
        }
    }

    override func reset() {
        super.reset()
        currentSeed = 0
        seedChangeCounter = 0
    }

    override func copy() -> Effect {
        BlockFreezeMetalEffect(blockSize: blockSize, freezeAmount: freezeAmount, streakAmount: streakAmount)
    }
}
