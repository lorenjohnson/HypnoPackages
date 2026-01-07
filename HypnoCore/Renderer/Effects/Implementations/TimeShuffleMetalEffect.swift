//
//  TimeShuffleMetalEffect.swift
//  Hypnograph
//
//  Time shuffle - swaps chunks of frames out of order.
//  Screen regions show different temporal chunks, like scrambled tape.
//  Simple and organic degradation feel.
//

import Foundation
import CoreImage
import CoreVideo
import Metal

/// GPU parameters - must match TimeShuffleShader.metal
struct TimeShuffleParamsGPU {
    var textureWidth: Int32
    var textureHeight: Int32
    var numRegions: Int32
    var depth: Int32          // How far back in time (for shader info)
    var maxHistoryFrames: Int32
    var shuffleSeed: UInt32
    var orientation: Int32    // 0 = horizontal, 1 = vertical, 2 = diagonal
}

/// Time shuffle - regions show different chunks of frame history
final class TimeShuffleMetalEffect: MetalEffect {

    // MARK: - Parameter Specs

    override class var parameterSpecs: [String: ParameterSpec] {
        [
            "numRegions": .int(default: 4, range: 2...8),
            "depth": .int(default: 60, range: 20...200),       // How far back in time to sample
            "shuffleRate": .float(default: 0.05, range: 0...0.3)  // How often pattern changes
        ]
    }

    // MARK: - Properties

    override var name: String { "Time Shuffle" }
    override var requiredLookback: Int { 300 }  // Need deep history
    override var shaderFunctionName: String { "timeShuffleKernel" }

    var numRegions: Int      // How many regions to divide into
    var depth: Int           // How far back in time to sample (frames)
    var shuffleRate: Float   // Probability of reshuffling per frame

    // Shuffle state
    private var currentSeed: UInt32 = 0
    private var frameCounter: Int = 0

    // MARK: - Init

    init(numRegions: Int, depth: Int, shuffleRate: Float) {
        self.numRegions = max(2, min(8, numRegions))
        self.depth = max(20, min(200, depth))
        self.shuffleRate = max(0, min(0.3, shuffleRate))
        super.init()
        setupMetal()
    }

    required convenience init?(params: [String: AnyCodableValue]?) {
        let p = Params(params, specs: Self.parameterSpecs)
        self.init(numRegions: p.int("numRegions"), depth: p.int("depth"), shuffleRate: p.float("shuffleRate"))
    }

    // MARK: - Effect Protocol

    override func apply(to image: CIImage, context: inout RenderContext) -> CIImage {
        frameCounter += 1

        // Randomly reshuffle based on shuffleRate - this changes the pattern
        if Float.random(in: 0...1) < shuffleRate {
            currentSeed = UInt32.random(in: 0..<UInt32.max)
        }

        // Need some history
        let frameCount = context.frameBuffer.frameCount
        let minFrames = max(8, depth / 4)  // Need at least some history
        guard frameCount >= minFrames else { return image }
        guard isMetalReady else { return image }

        let extent = image.extent
        let width = Int(extent.width)
        let height = Int(extent.height)
        guard width > 0, height > 0 else { return image }

        // Use seed to generate random but stable offsets within depth range
        var rng = currentSeed
        func nextRandom() -> Int {
            rng = rng &* 1103515245 &+ 12345
            return Int((rng >> 16) & 0x7FFF)
        }

        let maxOffset = min(depth, frameCount - 1)
        var historyTextures: [MTLTexture] = []

        // Always include current frame (offset 0) for continuity
        if let tex = context.frameBuffer.texture(atHistoryOffset: 0) {
            historyTextures.append(tex)
        }

        // 7 more random offsets within depth
        for _ in 0..<7 {
            let offset = nextRandom() % max(1, maxOffset)
            if let tex = context.frameBuffer.texture(atHistoryOffset: offset) {
                historyTextures.append(tex)
            }
        }

        // Pad with first texture if needed
        while historyTextures.count < 8 {
            if let first = historyTextures.first {
                historyTextures.append(first)
            } else {
                return image
            }
        }

        ensureBuffers(width: width, height: height, names: ["output"])
        guard let outputTexture = texture(from: buffer(named: "output")!) else {
            return image
        }

        // Orientation derived from seed (stable until reshuffle)
        let orientation = Int32(currentSeed % 3)

        var gpuParams = TimeShuffleParamsGPU(
            textureWidth: Int32(width),
            textureHeight: Int32(height),
            numRegions: Int32(numRegions),
            depth: Int32(depth),
            maxHistoryFrames: Int32(frameCount),
            shuffleSeed: currentSeed,
            orientation: orientation
        )

        return runShader(outputBufferName: "output", fallback: image) { encoder in
            for (i, tex) in historyTextures.enumerated() {
                encoder.setTexture(tex, index: i)
            }
            encoder.setTexture(outputTexture, index: 8)
            encoder.setBytes(&gpuParams, length: MemoryLayout<TimeShuffleParamsGPU>.stride, index: 0)
        }
    }

    override func reset() {
        super.reset()
        currentSeed = 0
        frameCounter = 0
    }

    override func copy() -> Effect {
        TimeShuffleMetalEffect(numRegions: numRegions, depth: depth, shuffleRate: shuffleRate)
    }
}
