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
final class TimeShuffleMetalEffect: Effect {

    // MARK: - Parameter Specs

    static var parameterSpecs: [String: ParameterSpec] {
        [
            "numRegions": .int(default: 4, range: 2...8),
            "depth": .int(default: 60, range: 20...200),       // How far back in time to sample
            "shuffleRate": .float(default: 0.05, range: 0...0.3)  // How often pattern changes
        ]
    }

    // MARK: - Properties

    var name: String { "Time Shuffle" }
    var requiredLookback: Int { 300 }  // Need deep history

    var numRegions: Int      // How many regions to divide into
    var depth: Int           // How far back in time to sample (frames)
    var shuffleRate: Float   // Probability of reshuffling per frame

    // Metal state
    private let device: MTLDevice?
    private let commandQueue: MTLCommandQueue?
    private var pipelineState: MTLComputePipelineState?
    private var textureCache: CVMetalTextureCache?

    // Output buffer
    private var outputBuffer: CVPixelBuffer?

    // Shuffle state
    private var currentSeed: UInt32 = 0
    private var frameCounter: Int = 0

    // MARK: - Init

    init(numRegions: Int, depth: Int, shuffleRate: Float) {
        self.numRegions = max(2, min(8, numRegions))
        self.depth = max(20, min(200, depth))
        self.shuffleRate = max(0, min(0.3, shuffleRate))

        self.device = MTLCreateSystemDefaultDevice()
        self.commandQueue = device?.makeCommandQueue()

        if let device = device {
            var cache: CVMetalTextureCache?
            CVMetalTextureCacheCreate(kCFAllocatorDefault, nil, device, nil, &cache)
            self.textureCache = cache
        }

        loadShader()
    }

    required convenience init?(params: [String: AnyCodableValue]?) {
        let p = Params(params, specs: Self.parameterSpecs)
        self.init(numRegions: p.int("numRegions"), depth: p.int("depth"), shuffleRate: p.float("shuffleRate"))
    }

    private func loadShader() {
        guard let device = device else { return }

        do {
            let library = try device.makeDefaultLibrary(bundle: HypnoEffectsBundle.bundle)
            guard let function = library.makeFunction(name: "timeShuffleKernel") else {
                print("⚠️ TimeShuffleMetalEffect: Kernel not found")
                return
            }
            pipelineState = try device.makeComputePipelineState(function: function)
        } catch {
            print("⚠️ TimeShuffleMetalEffect: Pipeline error: \(error)")
        }
    }

    private func ensureOutputBuffer(width: Int, height: Int) {
        if let buf = outputBuffer,
           CVPixelBufferGetWidth(buf) == width,
           CVPixelBufferGetHeight(buf) == height {
            return
        }

        let attrs: [String: Any] = [
            kCVPixelBufferMetalCompatibilityKey as String: true,
            kCVPixelBufferIOSurfacePropertiesKey as String: [:]
        ]
        CVPixelBufferCreate(kCFAllocatorDefault, width, height,
                           kCVPixelFormatType_32BGRA, attrs as CFDictionary, &outputBuffer)
    }

    private func textureFromBuffer(_ buffer: CVPixelBuffer) -> MTLTexture? {
        guard let cache = textureCache else { return nil }
        let w = CVPixelBufferGetWidth(buffer)
        let h = CVPixelBufferGetHeight(buffer)
        var cvTex: CVMetalTexture?
        let status = CVMetalTextureCacheCreateTextureFromImage(
            kCFAllocatorDefault, cache, buffer, nil, .bgra8Unorm, w, h, 0, &cvTex
        )
        guard status == kCVReturnSuccess, let tex = cvTex else { return nil }
        return CVMetalTextureGetTexture(tex)
    }

    // MARK: - Effect Protocol

    func apply(to image: CIImage, context: inout RenderContext) -> CIImage {
        frameCounter += 1

        // Randomly reshuffle based on shuffleRate - this changes the pattern
        if Float.random(in: 0...1) < shuffleRate {
            currentSeed = UInt32.random(in: 0..<UInt32.max)
        }

        // Need some history
        let frameCount = context.frameBuffer.frameCount
        let minFrames = max(8, depth / 4)  // Need at least some history
        guard frameCount >= minFrames else { return image }

        guard let _ = device,
              let commandQueue = commandQueue,
              let pipeline = pipelineState else {
            return image
        }

        let extent = image.extent
        let width = Int(extent.width)
        let height = Int(extent.height)
        guard width > 0, height > 0 else { return image }

        // Use seed to generate random but stable offsets within depth range
        // This creates temporal variety - each slot shows a random point in history
        // Offsets are regenerated each time seed changes (on shuffle)
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

        ensureOutputBuffer(width: width, height: height)
        guard let outBuf = outputBuffer,
              let outputTexture = textureFromBuffer(outBuf) else {
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

        guard let commandBuffer = commandQueue.makeCommandBuffer(),
              let encoder = commandBuffer.makeComputeCommandEncoder() else {
            return image
        }

        encoder.setComputePipelineState(pipeline)
        for (i, tex) in historyTextures.enumerated() {
            encoder.setTexture(tex, index: i)
        }
        encoder.setTexture(outputTexture, index: 8)
        encoder.setBytes(&gpuParams, length: MemoryLayout<TimeShuffleParamsGPU>.stride, index: 0)

        let threadWidth = pipeline.threadExecutionWidth
        let threadHeight = pipeline.maxTotalThreadsPerThreadgroup / threadWidth
        let threadsPerGroup = MTLSize(width: threadWidth, height: threadHeight, depth: 1)
        let threadgroups = MTLSize(
            width: (width + threadWidth - 1) / threadWidth,
            height: (height + threadHeight - 1) / threadHeight,
            depth: 1
        )

        encoder.dispatchThreadgroups(threadgroups, threadsPerThreadgroup: threadsPerGroup)
        encoder.endEncoding()
        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()

        return CIImage(cvPixelBuffer: outBuf)
    }

    func reset() {
        outputBuffer = nil
        currentSeed = 0
        frameCounter = 0
    }

    func copy() -> Effect {
        TimeShuffleMetalEffect(numRegions: numRegions, depth: depth, shuffleRate: shuffleRate)
    }
}

