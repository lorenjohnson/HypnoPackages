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
/// Demonstrates clean Metal shader integration pattern.
final class PixelateMetalEffect: Effect {

    // MARK: - Parameter Specs (source of truth)

    static var parameterSpecs: [String: ParameterSpec] {
        [
            "blockSize": .int(default: 8, range: 1...512)
        ]
    }

    // MARK: - Properties

    var name: String { customName ?? "Metal Basic" }
    var requiredLookback: Int { 0 }  // No frame history needed

    // MARK: - Configuration

    private let customName: String?
    var blockSize: Int

    // MARK: - Metal State

    private let device: MTLDevice?
    private let commandQueue: MTLCommandQueue?
    private var pipelineState: MTLComputePipelineState?
    private let ciContext: CIContext

    // MARK: - Init

    init(blockSize: Int, name: String? = nil) {
        self.blockSize = max(1, blockSize)
        self.customName = name
        self.device = MTLCreateSystemDefaultDevice()
        self.commandQueue = device?.makeCommandQueue()

        // Create CIContext backed by Metal for efficient texture conversion
        if let device = device {
            self.ciContext = CIContext(mtlDevice: device, options: [.cacheIntermediates: false])
        } else {
            self.ciContext = CIContext()
        }

        loadShader()
    }

    required convenience init?(params: [String: AnyCodableValue]?) {
        let p = Params(params, specs: Self.parameterSpecs)
        self.init(blockSize: p.int("blockSize"))
    }
    
    private func loadShader() {
        guard let device = device else {
            print("⚠️ PixelateMetalEffect: No Metal device")
            return
        }
        
        do {
            let library = try device.makeDefaultLibrary(bundle: HypnoEffectsBundle.bundle)
            guard let function = library.makeFunction(name: "pixelateKernel") else {
                print("⚠️ PixelateMetalEffect: Kernel function not found")
                return
            }
            pipelineState = try device.makeComputePipelineState(function: function)
        } catch {
            print("⚠️ PixelateMetalEffect: Failed to create pipeline: \(error)")
        }
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
        
        // Create textures
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
        ciContext.render(image, to: inputTexture, commandBuffer: nil, bounds: extent, colorSpace: colorSpace)
        
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
        
        // Calculate threadgroup size
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
        
        // Convert back to CIImage
        guard let outputImage = CIImage(mtlTexture: outputTexture, options: [.colorSpace: colorSpace]) else {
            return image
        }

        return outputImage
    }
    
    func copy() -> Effect {
        PixelateMetalEffect(blockSize: blockSize, name: customName)
    }
}

