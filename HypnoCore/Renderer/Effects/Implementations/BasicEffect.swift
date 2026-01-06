//
//  BasicEffect.swift
//  Hypnograph
//
//  Basic image adjustments via Metal compute shader.
//  Provides opacity, contrast, brightness, and saturation controls.
//

import Foundation
import CoreImage
import Metal

/// Color space options for BasicEffect
enum BasicColorSpace: String, CaseIterable {
    case rgb = "rgb"
    case yuv = "yuv"
    case hsv = "hsv"
    case lab = "lab"

    var displayLabel: String {
        switch self {
        case .rgb: return "RGB"
        case .yuv: return "YUV"
        case .hsv: return "HSV"
        case .lab: return "LAB"
        }
    }

    /// GPU index for shader
    var gpuIndex: Int32 {
        switch self {
        case .rgb: return 0
        case .yuv: return 1
        case .hsv: return 2
        case .lab: return 3
        }
    }
}

/// GPU parameters struct - must match layout in BasicShader.metal
struct BasicParamsGPU {
    var contrast: Float
    var brightness: Float
    var saturation: Float
    var hueShift: Float
    var colorSpace: Int32      // 0=RGB, 1=YUV, 2=HSV, 3=LAB
    var invert: Int32          // 0=false, 1=true
    var textureWidth: Int32
    var textureHeight: Int32
}

/// Basic image adjustments effect.
/// Provides contrast, brightness, saturation, hue, and invert controls.
final class BasicEffect: Effect {

    // MARK: - Parameter Specs (source of truth)

    static var parameterSpecs: [String: ParameterSpec] {
        [
            "contrast": .float(default: 0.0, range: -1...1),
            "brightness": .float(default: 0.0, range: -1...1),
            "saturation": .float(default: 0.0, range: -1...1),
            "hueShift": .float(default: 0.0, range: -1...1),
            "colorSpace": .choice(default: "rgb", options: BasicColorSpace.allCases.map { ($0.rawValue, $0.displayLabel) }),
            "invert": .bool(default: false)
        ]
    }

    // MARK: - Properties

    var name: String { customName ?? "Basic" }
    var requiredLookback: Int { 0 }  // No frame history needed

    // MARK: - Configuration

    private let customName: String?
    var contrast: Float
    var brightness: Float
    var saturation: Float
    var hueShift: Float
    var colorSpace: BasicColorSpace
    var invert: Bool

    // MARK: - Metal State

    private let device: MTLDevice?
    private let commandQueue: MTLCommandQueue?
    private var pipelineState: MTLComputePipelineState?
    private let ciContext: CIContext

    // MARK: - Init

    init(contrast: Float, brightness: Float, saturation: Float,
         hueShift: Float, colorSpace: BasicColorSpace, invert: Bool, name: String? = nil) {
        self.contrast = max(-1, min(1, contrast))
        self.brightness = max(-1, min(1, brightness))
        self.saturation = max(-1, min(1, saturation))
        self.hueShift = max(-1, min(1, hueShift))
        self.colorSpace = colorSpace
        self.invert = invert
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
        let colorSpace = BasicColorSpace(rawValue: p.string("colorSpace")) ?? .rgb
        self.init(contrast: p.float("contrast"),
                  brightness: p.float("brightness"), saturation: p.float("saturation"),
                  hueShift: p.float("hueShift"), colorSpace: colorSpace, invert: p.bool("invert"))
    }

    private func loadShader() {
        guard let device = device else {
            print("⚠️ BasicEffect: No Metal device")
            return
        }

        do {
            let library = try device.makeDefaultLibrary(bundle: HypnoEffectsBundle.bundle)
            guard let function = library.makeFunction(name: "basicKernel") else {
                print("⚠️ BasicEffect: Kernel function not found")
                return
            }
            pipelineState = try device.makeComputePipelineState(function: function)
        } catch {
            print("⚠️ BasicEffect: Failed to create pipeline: \(error)")
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
        let cgColorSpace = CGColorSpaceCreateDeviceRGB()
        ciContext.render(image, to: inputTexture, commandBuffer: nil, bounds: extent, colorSpace: cgColorSpace)

        // Setup GPU params
        var gpuParams = BasicParamsGPU(
            contrast: contrast,
            brightness: brightness,
            saturation: saturation,
            hueShift: hueShift,
            colorSpace: colorSpace.gpuIndex,
            invert: invert ? 1 : 0,
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
        encoder.setBytes(&gpuParams, length: MemoryLayout<BasicParamsGPU>.stride, index: 0)

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
        guard let outputImage = CIImage(mtlTexture: outputTexture, options: [.colorSpace: cgColorSpace]) else {
            return image
        }

        return outputImage
    }

    func copy() -> Effect {
        BasicEffect(contrast: contrast, brightness: brightness,
                  saturation: saturation, hueShift: hueShift, colorSpace: colorSpace,
                  invert: invert, name: customName)
    }
}

