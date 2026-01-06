//
//  IFrameCompressEffect.swift
//  Hypnograph
//
//  I-frame style temporal compression via Metal GPU.
//  Keeps a reference "I-frame" and compresses differences.
//  Errors accumulate over time creating drift/degradation.
//

import Foundation
import CoreImage
import Metal

/// GPU parameters - must match IFrameShader.metal
struct IFrameParamsGPU {
    var textureWidth: Int32
    var textureHeight: Int32
    var stickiness: Float
    var quality: Float
    var glitch: Float
    var diffThreshold: Float
    var isIFrame: Int32
    var frameNumber: Int32
}

/// I-frame temporal compression with content-adaptive resets
/// Pixels reset when difference exceeds threshold, otherwise accumulate damage
final class IFrameCompressEffect: Effect {

    // MARK: - Parameter Specs

    static var parameterSpecs: [String: ParameterSpec] {
        [
            "quality": .float(default: 0.5, range: 0.01...1.0),
            "stickiness": .float(default: 0.92, range: 0.5...0.999),
            "glitch": .float(default: 0.0, range: 0.0...1.0),
            "diffThreshold": .float(default: 0.3, range: 0.05...0.95),
            "iframeInterval": .int(default: 300, range: 30...1000)  // Backstop, rarely hit
        ]
    }

    // MARK: - Properties

    var name: String { "I-Frame Compress" }
    var requiredLookback: Int { 0 }

    var quality: Float
    var iframeInterval: Int
    var stickiness: Float      // How much reference resists updating
    var glitch: Float          // Motion-driven trail intensity
    var diffThreshold: Float   // Difference threshold for adaptive reset

    // Metal state
    private let device: MTLDevice?
    private let commandQueue: MTLCommandQueue?
    private var pipelineState: MTLComputePipelineState?
    private let ciContext: CIContext

    // Frame state
    private var referenceTexture: MTLTexture?
    private var framesSinceIframe: Int = 0
    private var frameNumber: Int = 0

    // MARK: - Init

    init(quality: Float, iframeInterval: Int, stickiness: Float, glitch: Float, diffThreshold: Float) {
        self.quality = max(0.01, min(1.0, quality))
        self.iframeInterval = max(30, min(1000, iframeInterval))
        self.stickiness = max(0.5, min(0.999, stickiness))
        self.glitch = max(0.0, min(1.0, glitch))
        self.diffThreshold = max(0.05, min(0.95, diffThreshold))

        self.device = MTLCreateSystemDefaultDevice()
        self.commandQueue = device?.makeCommandQueue()

        if let device = device {
            self.ciContext = CIContext(mtlDevice: device, options: [.cacheIntermediates: false])
        } else {
            self.ciContext = CIContext()
        }

        loadShader()
    }

    required convenience init?(params: [String: AnyCodableValue]?) {
        let p = Params(params, specs: Self.parameterSpecs)
        self.init(quality: p.float("quality"), iframeInterval: p.int("iframeInterval"),
                  stickiness: p.float("stickiness"), glitch: p.float("glitch"), diffThreshold: p.float("diffThreshold"))
    }

    private func loadShader() {
        guard let device = device else { return }

        do {
            let library = try device.makeDefaultLibrary(bundle: HypnoEffectsBundle.bundle)
            guard let function = library.makeFunction(name: "iframeAccumulateKernel") else {
                print("⚠️ IFrameCompressEffect: Kernel not found")
                return
            }
            pipelineState = try device.makeComputePipelineState(function: function)
        } catch {
            print("⚠️ IFrameCompressEffect: Pipeline error: \(error)")
        }
    }

    private func ensureReferenceTexture(width: Int, height: Int) {
        if let tex = referenceTexture, tex.width == width, tex.height == height {
            return
        }

        let desc = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .rgba8Unorm,
            width: width,
            height: height,
            mipmapped: false
        )
        desc.usage = [.shaderRead, .shaderWrite]
        referenceTexture = device?.makeTexture(descriptor: desc)
        framesSinceIframe = iframeInterval  // Force I-frame on resize
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

        ensureReferenceTexture(width: width, height: height)
        guard let refTex = referenceTexture else { return image }

        // Create input texture from current frame
        let inputDesc = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .rgba8Unorm, width: width, height: height, mipmapped: false
        )
        inputDesc.usage = [.shaderRead, .shaderWrite]  // Need write for CIContext render
        guard let inputTexture = device.makeTexture(descriptor: inputDesc) else {
            return image
        }

        // Create output texture
        let outputDesc = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .rgba8Unorm, width: width, height: height, mipmapped: false
        )
        outputDesc.usage = [.shaderRead, .shaderWrite]
        guard let outputTexture = device.makeTexture(descriptor: outputDesc) else {
            return image
        }

        // Render CIImage to input texture
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        ciContext.render(image, to: inputTexture, commandBuffer: nil,
                        bounds: extent, colorSpace: colorSpace)

        framesSinceIframe += 1
        frameNumber += 1
        let isIFrame = framesSinceIframe >= iframeInterval ? 1 : 0
        if isIFrame == 1 {
            framesSinceIframe = 0
        }

        var gpuParams = IFrameParamsGPU(
            textureWidth: Int32(width),
            textureHeight: Int32(height),
            stickiness: stickiness,
            quality: quality,
            glitch: glitch,
            diffThreshold: diffThreshold,
            isIFrame: Int32(isIFrame),
            frameNumber: Int32(frameNumber)
        )

        guard let commandBuffer = commandQueue.makeCommandBuffer(),
              let encoder = commandBuffer.makeComputeCommandEncoder() else {
            return image
        }

        encoder.setComputePipelineState(pipeline)
        encoder.setTexture(inputTexture, index: 0)
        encoder.setTexture(refTex, index: 1)
        encoder.setTexture(outputTexture, index: 2)
        encoder.setBytes(&gpuParams, length: MemoryLayout<IFrameParamsGPU>.stride, index: 0)

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

        guard let result = CIImage(mtlTexture: outputTexture, options: [.colorSpace: colorSpace]) else {
            return image
        }

        return result
    }

    func reset() {
        referenceTexture = nil
        // Force I-frame on next render by setting counter to interval
        framesSinceIframe = iframeInterval
        frameNumber = 0
    }

    func copy() -> Effect {
        IFrameCompressEffect(quality: quality, iframeInterval: iframeInterval, stickiness: stickiness,
                          glitch: glitch, diffThreshold: diffThreshold)
    }
}

