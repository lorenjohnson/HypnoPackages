//
//  PixelateMetalEffect.swift
//  Hypnograph
//
//  Simple Metal compute shader-based pixelate effect.
//  Demonstrates the basic pattern for Metal-based effects.
//

import Foundation
import CoreImage
import Metal

/// GPU parameters struct - must match layout in PixelateShader.metal
struct PixelateParamsGPU {
    var blockSize: Int32
    var textureWidth: Int32
    var textureHeight: Int32
}

/// Simple Metal-based pixelate effect.
/// Uses direct MTLTexture creation for simple single-pass effects.
final class PixelateMetalEffect: MetalEffect {

    // MARK: - Parameter Specs (source of truth)

    override class var parameterSpecs: [String: ParameterSpec] {
        [
            "blockSize": .int(default: 8, range: 1...512)
        ]
    }

    // MARK: - Properties

    override var name: String { customName ?? "Metal Basic" }
    override var shaderFunctionName: String { "pixelateKernel" }

    private let customName: String?
    var blockSize: Int

    // CIContext for texture rendering
    private var ciContext: CIContext?

    // MARK: - Init

    init(blockSize: Int, name: String? = nil) {
        self.blockSize = max(1, blockSize)
        self.customName = name
        super.init()
        setupMetal()

        // Create CIContext backed by Metal for efficient texture conversion
        if let device = device {
            self.ciContext = CIContext(mtlDevice: device, options: [.cacheIntermediates: false])
        }
    }

    required convenience init?(params: [String: AnyCodableValue]?) {
        let p = Params(params, specs: Self.parameterSpecs)
        self.init(blockSize: p.int("blockSize"))
    }

    // MARK: - Effect Protocol

    override func apply(to image: CIImage, context: inout RenderContext) -> CIImage {
        guard isMetalReady,
              let device = device,
              let commandQueue = commandQueue,
              let pipeline = pipelineState,
              let ciCtx = ciContext else {
            return image
        }

        let extent = image.extent
        let width = Int(extent.width)
        let height = Int(extent.height)
        guard width > 0, height > 0 else { return image }

        // Create textures directly (no CVPixelBuffer needed for simple effects)
        let textureDescriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .rgba8Unorm,
            width: width,
            height: height,
            mipmapped: false
        )
        textureDescriptor.usage = [.shaderRead, .shaderWrite]

        guard let inputTexture = device.makeTexture(descriptor: textureDescriptor),
              let outputTexture = device.makeTexture(descriptor: textureDescriptor) else {
            return image
        }

        // Render CIImage to input texture
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        ciCtx.render(image, to: inputTexture, commandBuffer: nil, bounds: extent, colorSpace: colorSpace)

        // Setup GPU params
        var gpuParams = PixelateParamsGPU(
            blockSize: Int32(blockSize),
            textureWidth: Int32(width),
            textureHeight: Int32(height)
        )

        // Run compute shader
        guard let commandBuffer = commandQueue.makeCommandBuffer(),
              let encoder = commandBuffer.makeComputeCommandEncoder() else {
            return image
        }

        encoder.setComputePipelineState(pipeline)
        encoder.setTexture(inputTexture, index: 0)
        encoder.setTexture(outputTexture, index: 1)
        encoder.setBytes(&gpuParams, length: MemoryLayout<PixelateParamsGPU>.stride, index: 0)

        let (groups, threadsPerGroup) = threadgroupConfig(for: (width, height))
        encoder.dispatchThreadgroups(groups, threadsPerThreadgroup: threadsPerGroup)
        encoder.endEncoding()
        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()

        // Convert back to CIImage
        guard let outputImage = CIImage(mtlTexture: outputTexture, options: [.colorSpace: colorSpace]) else {
            return image
        }

        return outputImage
    }

    override func copy() -> Effect {
        PixelateMetalEffect(blockSize: blockSize, name: customName)
    }
}
