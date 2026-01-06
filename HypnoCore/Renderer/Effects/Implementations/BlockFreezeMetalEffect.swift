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
final class BlockFreezeMetalEffect: Effect {

    // MARK: - Parameter Specs

    static var parameterSpecs: [String: ParameterSpec] {
        [
            "blockSize": .int(default: 24, range: 8...128),
            "freezeAmount": .float(default: 0.4, range: 0...1),
            "streakAmount": .float(default: 0.3, range: 0...1)
        ]
    }

    // MARK: - Properties

    var name: String { "Block Freeze" }
    var requiredLookback: Int { 30 }

    var blockSize: Int
    var freezeAmount: Float
    var streakAmount: Float

    // Metal state
    private let device: MTLDevice?
    private let commandQueue: MTLCommandQueue?
    private var pipelineState: MTLComputePipelineState?
    private var textureCache: CVMetalTextureCache?

    // Reusable buffers
    private var inputBuffer: CVPixelBuffer?
    private var outputBuffer: CVPixelBuffer?
    private var frameCounter: UInt32 = 0

    // Seed changes slowly for stable blocks
    private var currentSeed: UInt32 = 0
    private var seedChangeCounter: Int = 0

    // MARK: - Init

    init(blockSize: Int, freezeAmount: Float, streakAmount: Float) {
        self.blockSize = max(8, min(128, blockSize))
        self.freezeAmount = max(0, min(1, freezeAmount))
        self.streakAmount = max(0, min(1, streakAmount))

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
        self.init(blockSize: p.int("blockSize"), freezeAmount: p.float("freezeAmount"), streakAmount: p.float("streakAmount"))
    }

    private func loadShader() {
        guard let device = device else { return }

        do {
            let library = try device.makeDefaultLibrary(bundle: HypnoEffectsBundle.bundle)
            guard let function = library.makeFunction(name: "blockFreezeKernel") else {
                print("⚠️ BlockFreezeMetalEffect: Kernel not found")
                return
            }
            pipelineState = try device.makeComputePipelineState(function: function)
        } catch {
            print("⚠️ BlockFreezeMetalEffect: Pipeline error: \(error)")
        }
    }

    // MARK: - Buffer Management

    private func ensureBuffers(width: Int, height: Int) {
        if let buf = inputBuffer,
           CVPixelBufferGetWidth(buf) == width,
           CVPixelBufferGetHeight(buf) == height {
            return
        }

        let attrs: [String: Any] = [
            kCVPixelBufferMetalCompatibilityKey as String: true,
            kCVPixelBufferIOSurfacePropertiesKey as String: [:]
        ]

        CVPixelBufferCreate(kCFAllocatorDefault, width, height,
                           kCVPixelFormatType_32BGRA, attrs as CFDictionary, &inputBuffer)
        CVPixelBufferCreate(kCFAllocatorDefault, width, height,
                           kCVPixelFormatType_32BGRA, attrs as CFDictionary, &outputBuffer)
    }

    private func textureFromBuffer(_ buffer: CVPixelBuffer) -> MTLTexture? {
        guard let cache = textureCache else { return nil }
        let width = CVPixelBufferGetWidth(buffer)
        let height = CVPixelBufferGetHeight(buffer)

        var cvTexture: CVMetalTexture?
        let status = CVMetalTextureCacheCreateTextureFromImage(
            kCFAllocatorDefault, cache, buffer, nil,
            .bgra8Unorm, width, height, 0, &cvTexture
        )
        guard status == kCVReturnSuccess, let tex = cvTexture else { return nil }
        return CVMetalTextureGetTexture(tex)
    }

    // MARK: - Effect Protocol

    func apply(to image: CIImage, context: inout RenderContext) -> CIImage {
        frameCounter &+= 1

        // Update seed slowly (every ~15 frames) for stable freeze pattern
        seedChangeCounter += 1
        if seedChangeCounter >= 15 {
            seedChangeCounter = 0
            currentSeed = UInt32.random(in: 0..<UInt32.max)
        }

        // Need some history
        guard context.frameBuffer.frameCount >= 5 else { return image }

        guard let device = device,
              let commandQueue = commandQueue,
              let pipeline = pipelineState else {
            return image
        }

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
        ensureBuffers(width: width, height: height)
        guard let inBuf = inputBuffer, let outBuf = outputBuffer else { return image }

        // Render current to input buffer
        SharedRenderer.ciContext.render(image, to: inBuf, bounds: extent,
                                        colorSpace: CGColorSpaceCreateDeviceRGB())

        guard let currentTexture = textureFromBuffer(inBuf),
              let outputTexture = textureFromBuffer(outBuf) else {
            return image
        }

        // Setup params
        var gpuParams = BlockFreezeParamsGPU(
            textureWidth: Int32(width),
            textureHeight: Int32(height),
            blockSize: Int32(blockSize),
            freezeChance: freezeAmount,
            streakChance: streakAmount,
            randomSeed: currentSeed
        )

        // Run shader
        guard let commandBuffer = commandQueue.makeCommandBuffer(),
              let encoder = commandBuffer.makeComputeCommandEncoder() else {
            return image
        }

        encoder.setComputePipelineState(pipeline)
        encoder.setTexture(currentTexture, index: 0)
        encoder.setTexture(historyTexture, index: 1)
        encoder.setTexture(outputTexture, index: 2)
        encoder.setBytes(&gpuParams, length: MemoryLayout<BlockFreezeParamsGPU>.stride, index: 0)

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
        inputBuffer = nil
        outputBuffer = nil
        frameCounter = 0
        currentSeed = 0
        seedChangeCounter = 0
    }

    func copy() -> Effect {
        BlockFreezeMetalEffect(blockSize: blockSize, freezeAmount: freezeAmount, streakAmount: streakAmount)
    }
}

