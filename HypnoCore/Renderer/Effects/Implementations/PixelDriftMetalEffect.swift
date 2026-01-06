//
//  PixelDriftMetalEffect.swift
//  Hypnograph
//
//  Pixel drift effect - pixels smear in direction of motion.
//  Creates organic trails where movement occurs, clean elsewhere.
//  Simple 3-parameter effect.
//

import Foundation
import CoreImage
import CoreVideo
import Metal

/// GPU parameters - must match PixelDriftShader.metal
struct PixelDriftParamsGPU {
    var textureWidth: Int32
    var textureHeight: Int32
    var driftStrength: Float
    var threshold: Float
    var decay: Float
    var randomSeed: UInt32
}

/// Pixel drift effect - motion causes smearing trails
final class PixelDriftMetalEffect: Effect {

    // MARK: - Parameter Specs

    static var parameterSpecs: [String: ParameterSpec] {
        [
            "driftStrength": .float(default: 8.0, range: 1...30),
            "threshold": .float(default: 0.05, range: 0...0.5),
            "decay": .float(default: 0.6, range: 0...1)
        ]
    }

    // MARK: - Properties

    var name: String { "Pixel Drift" }
    var requiredLookback: Int { 5 }

    var driftStrength: Float
    var threshold: Float
    var decay: Float

    // Metal state
    private let device: MTLDevice?
    private let commandQueue: MTLCommandQueue?
    private var pipelineState: MTLComputePipelineState?
    private var textureCache: CVMetalTextureCache?

    // Buffers
    private var inputBuffer: CVPixelBuffer?
    private var outputBuffer: CVPixelBuffer?
    private var feedbackBuffer: CVPixelBuffer?
    private var frameCounter: UInt32 = 0

    // MARK: - Init

    init(driftStrength: Float, threshold: Float, decay: Float) {
        self.driftStrength = max(1, min(30, driftStrength))
        self.threshold = max(0, min(0.5, threshold))
        self.decay = max(0, min(1, decay))

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
        self.init(driftStrength: p.float("driftStrength"), threshold: p.float("threshold"), decay: p.float("decay"))
    }

    private func loadShader() {
        guard let device = device else { return }

        do {
            let library = try device.makeDefaultLibrary(bundle: HypnoEffectsBundle.bundle)
            guard let function = library.makeFunction(name: "pixelDriftKernel") else {
                print("⚠️ PixelDriftMetalEffect: Kernel not found")
                return
            }
            pipelineState = try device.makeComputePipelineState(function: function)
        } catch {
            print("⚠️ PixelDriftMetalEffect: Pipeline error: \(error)")
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
        CVPixelBufferCreate(kCFAllocatorDefault, width, height,
                           kCVPixelFormatType_32BGRA, attrs as CFDictionary, &feedbackBuffer)
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

        guard context.frameBuffer.frameCount >= 2 else { return image }

        guard let device = device,
              let commandQueue = commandQueue,
              let pipeline = pipelineState else {
            return image
        }

        let extent = image.extent
        let width = Int(extent.width)
        let height = Int(extent.height)
        guard width > 0, height > 0 else { return image }

        // Get previous frame for motion detection
        guard let previousTexture = context.frameBuffer.texture(atHistoryOffset: 1) else {
            return image
        }

        ensureBuffers(width: width, height: height)
        guard let inBuf = inputBuffer,
              let outBuf = outputBuffer,
              let fbBuf = feedbackBuffer else { return image }

        // Render current to input
        SharedRenderer.ciContext.render(image, to: inBuf, bounds: extent,
                                        colorSpace: CGColorSpaceCreateDeviceRGB())

        guard let currentTexture = textureFromBuffer(inBuf),
              let outputTexture = textureFromBuffer(outBuf),
              let feedbackTexture = textureFromBuffer(fbBuf) else {
            return image
        }

        var gpuParams = PixelDriftParamsGPU(
            textureWidth: Int32(width),
            textureHeight: Int32(height),
            driftStrength: driftStrength,
            threshold: threshold,
            decay: decay,
            randomSeed: frameCounter
        )

        guard let commandBuffer = commandQueue.makeCommandBuffer(),
              let encoder = commandBuffer.makeComputeCommandEncoder() else {
            return image
        }

        encoder.setComputePipelineState(pipeline)
        encoder.setTexture(currentTexture, index: 0)
        encoder.setTexture(previousTexture, index: 1)
        encoder.setTexture(feedbackTexture, index: 2)
        encoder.setTexture(outputTexture, index: 3)
        encoder.setBytes(&gpuParams, length: MemoryLayout<PixelDriftParamsGPU>.stride, index: 0)

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

        // Copy output to feedback for next frame
        let blitBuffer = commandQueue.makeCommandBuffer()
        if let blitEncoder = blitBuffer?.makeBlitCommandEncoder() {
            blitEncoder.copy(from: outputTexture, to: feedbackTexture)
            blitEncoder.endEncoding()
            blitBuffer?.commit()
            blitBuffer?.waitUntilCompleted()
        }

        return CIImage(cvPixelBuffer: outBuf)
    }

    func reset() {
        inputBuffer = nil
        outputBuffer = nil
        feedbackBuffer = nil
        frameCounter = 0
    }

    func copy() -> Effect {
        PixelDriftMetalEffect(driftStrength: driftStrength, threshold: threshold, decay: decay)
    }
}

