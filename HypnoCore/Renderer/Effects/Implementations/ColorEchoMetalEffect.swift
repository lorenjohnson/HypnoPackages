//
//  ColorEchoMetalEffect.swift
//  Hypnograph
//
//  Color echo effect via Metal compute shader.
//  Each RGB channel comes from a different point in time.
//  Single-pass implementation for efficiency.
//

import Foundation
import CoreImage
import CoreVideo
import Metal

/// GPU parameters struct - must match layout in ColorEchoShader.metal
struct ColorEchoParamsGPU {
    var intensity: Float
    var textureWidth: Int32
    var textureHeight: Int32
}

/// Color echo effect using Metal compute shader.
/// Red from current frame, green from N frames ago, blue from 2N frames ago.
final class ColorEchoMetalEffect: Effect {

    // MARK: - Parameter Specs (source of truth)

    static var parameterSpecs: [String: ParameterSpec] {
        [
            "channelOffset": .int(default: 4, range: 1...30),
            "intensity": .float(default: 1.0, range: 0.5...1.0)
        ]
    }

    // MARK: - Properties

    var name: String { customName ?? "Color Echo" }
    private let customName: String?

    /// Needs 2x channel offset frames (blue channel is furthest back)
    var requiredLookback: Int { channelOffset * 2 + 1 }

    let channelOffset: Int
    var intensity: Float

    // Metal resources
    private let device: MTLDevice?
    private let commandQueue: MTLCommandQueue?
    private var pipelineState: MTLComputePipelineState?
    private var textureCache: CVMetalTextureCache?

    // Reusable buffers
    private var inputBuffer: CVPixelBuffer?
    private var outputBuffer: CVPixelBuffer?

    // MARK: - Init

    init(channelOffset: Int, intensity: Float, name: String? = nil) {
        self.channelOffset = max(1, min(30, channelOffset))
        self.intensity = max(0.5, min(1.0, intensity))
        self.customName = name
        self.device = MTLCreateSystemDefaultDevice()
        self.commandQueue = device?.makeCommandQueue()

        // Create texture cache
        if let device = device {
            var cache: CVMetalTextureCache?
            CVMetalTextureCacheCreate(kCFAllocatorDefault, nil, device, nil, &cache)
            self.textureCache = cache
        }

        loadShader()
    }

    required convenience init?(params: [String: AnyCodableValue]?) {
        let p = Params(params, specs: Self.parameterSpecs)
        self.init(channelOffset: p.int("channelOffset"), intensity: p.float("intensity"))
    }

    private func loadShader() {
        guard let device = device else {
            print("⚠️ ColorEchoMetalEffect: No Metal device")
            return
        }

        do {
            let library = try device.makeDefaultLibrary(bundle: HypnoEffectsBundle.bundle)
            guard let function = library.makeFunction(name: "colorEchoKernel") else {
                print("⚠️ ColorEchoMetalEffect: Kernel function not found")
                return
            }
            pipelineState = try device.makeComputePipelineState(function: function)
        } catch {
            print("⚠️ ColorEchoMetalEffect: Failed to create pipeline: \(error)")
        }
    }

    // MARK: - Texture Management

    private func ensureBuffers(width: Int, height: Int) {
        // Check if existing buffers are correct size
        if let buf = inputBuffer,
           CVPixelBufferGetWidth(buf) == width,
           CVPixelBufferGetHeight(buf) == height {
            return
        }

        // Create new buffers
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
        guard let device = device,
              let commandQueue = commandQueue,
              let pipeline = pipelineState else {
            return image
        }

        let extent = image.extent
        let width = Int(extent.width)
        let height = Int(extent.height)

        guard width > 0, height > 0 else { return image }

        // Get frame buffer textures using texture() like DatamoshMetalEffect
        let maxOffset = max(0, context.frameBuffer.frameCount - 1)
        guard maxOffset >= 1 else { return image }

        let greenOffset = min(channelOffset, maxOffset)
        let blueOffset = min(channelOffset * 2, maxOffset)

        guard let greenTexture = context.frameBuffer.texture(atHistoryOffset: greenOffset),
              let blueTexture = context.frameBuffer.texture(atHistoryOffset: blueOffset) else {
            return image
        }

        // Ensure we have buffers
        ensureBuffers(width: width, height: height)

        guard let inBuf = inputBuffer, let outBuf = outputBuffer else { return image }

        // Render CIImage to input buffer (same coordinate system as frame buffer)
        SharedRenderer.ciContext.render(image, to: inBuf, bounds: extent,
                                        colorSpace: CGColorSpaceCreateDeviceRGB())

        // Convert buffers to textures
        guard let currentTexture = textureFromBuffer(inBuf),
              let outputTexture = textureFromBuffer(outBuf) else {
            return image
        }

        // Setup GPU params
        var gpuParams = ColorEchoParamsGPU(
            intensity: intensity,
            textureWidth: Int32(width),
            textureHeight: Int32(height)
        )

        // Run compute shader
        guard let commandBuffer = commandQueue.makeCommandBuffer(),
              let encoder = commandBuffer.makeComputeCommandEncoder() else {
            return image
        }

        encoder.setComputePipelineState(pipeline)
        encoder.setTexture(currentTexture, index: 0)
        encoder.setTexture(greenTexture, index: 1)
        encoder.setTexture(blueTexture, index: 2)
        encoder.setTexture(outputTexture, index: 3)
        encoder.setBytes(&gpuParams, length: MemoryLayout<ColorEchoParamsGPU>.stride, index: 0)

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

        // Convert output buffer back to CIImage
        return CIImage(cvPixelBuffer: outBuf)
    }

    func reset() {
        inputBuffer = nil
        outputBuffer = nil
    }

    func copy() -> Effect {
        ColorEchoMetalEffect(channelOffset: channelOffset, intensity: intensity, name: customName)
    }
}

