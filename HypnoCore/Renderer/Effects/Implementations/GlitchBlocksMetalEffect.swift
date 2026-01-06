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
final class GlitchBlocksMetalEffect: Effect {

    // MARK: - Parameter Specs

    static var parameterSpecs: [String: ParameterSpec] {
        [
            "blockSize": .int(default: 32, range: 8...128),
            "glitchAmount": .float(default: 0.3, range: 0...1),
            "corruption": .float(default: 0.5, range: 0...1)
        ]
    }

    // MARK: - Properties

    var name: String { "Glitch Blocks" }
    var requiredLookback: Int { 20 }

    var blockSize: Int
    var glitchAmount: Float
    var corruption: Float

    // Metal state
    private let device: MTLDevice?
    private let commandQueue: MTLCommandQueue?
    private var pipelineState: MTLComputePipelineState?
    private var textureCache: CVMetalTextureCache?

    // Buffers
    private var inputBuffer: CVPixelBuffer?
    private var outputBuffer: CVPixelBuffer?
    private var frameCounter: UInt32 = 0

    // Stable seed changes slowly
    private var stableSeed: UInt32 = 0
    private var seedCounter: Int = 0

    // MARK: - Init

    init(blockSize: Int, glitchAmount: Float, corruption: Float) {
        self.blockSize = max(8, min(128, blockSize))
        self.glitchAmount = max(0, min(1, glitchAmount))
        self.corruption = max(0, min(1, corruption))

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
        self.init(blockSize: p.int("blockSize"), glitchAmount: p.float("glitchAmount"), corruption: p.float("corruption"))
    }

    private func loadShader() {
        guard let device = device else { return }

        do {
            let library = try device.makeDefaultLibrary(bundle: HypnoEffectsBundle.bundle)
            guard let function = library.makeFunction(name: "glitchBlocksKernel") else {
                print("⚠️ GlitchBlocksMetalEffect: Kernel not found")
                return
            }
            pipelineState = try device.makeComputePipelineState(function: function)
        } catch {
            print("⚠️ GlitchBlocksMetalEffect: Pipeline error: \(error)")
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

        // Update stable seed every ~20 frames (pattern changes slowly)
        seedCounter += 1
        if seedCounter >= 20 {
            seedCounter = 0
            stableSeed = UInt32.random(in: 0..<UInt32.max)
        }

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

        // Get history from ~8 frames ago
        let historyOffset = min(8, context.frameBuffer.frameCount - 1)
        guard let historyTexture = context.frameBuffer.texture(atHistoryOffset: historyOffset) else {
            return image
        }

        ensureBuffers(width: width, height: height)
        guard let inBuf = inputBuffer, let outBuf = outputBuffer else { return image }

        SharedRenderer.ciContext.render(image, to: inBuf, bounds: extent,
                                        colorSpace: CGColorSpaceCreateDeviceRGB())

        guard let currentTexture = textureFromBuffer(inBuf),
              let outputTexture = textureFromBuffer(outBuf) else {
            return image
        }

        var gpuParams = GlitchBlocksParamsGPU(
            textureWidth: Int32(width),
            textureHeight: Int32(height),
            blockSize: Int32(blockSize),
            glitchAmount: glitchAmount,
            corruption: corruption,
            randomSeed: stableSeed,
            frameSeed: frameCounter
        )

        guard let commandBuffer = commandQueue.makeCommandBuffer(),
              let encoder = commandBuffer.makeComputeCommandEncoder() else {
            return image
        }

        encoder.setComputePipelineState(pipeline)
        encoder.setTexture(currentTexture, index: 0)
        encoder.setTexture(historyTexture, index: 1)
        encoder.setTexture(outputTexture, index: 2)
        encoder.setBytes(&gpuParams, length: MemoryLayout<GlitchBlocksParamsGPU>.stride, index: 0)

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
        stableSeed = 0
        seedCounter = 0
    }

    func copy() -> Effect {
        GlitchBlocksMetalEffect(blockSize: blockSize, glitchAmount: glitchAmount, corruption: corruption)
    }
}

