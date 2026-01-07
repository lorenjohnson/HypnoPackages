//
//  GaussianBlurMetalEffect.swift
//  Hypnograph
//
//  Gaussian blur effect via Metal compute shader.
//  Uses separable two-pass convolution for efficiency.
//

import Foundation
import CoreImage
import CoreVideo
import Metal

/// GPU parameters struct - must match layout in GaussianBlurShader.metal
struct GaussianBlurParamsGPU {
    var radius: Float
    var textureWidth: Int32
    var textureHeight: Int32
    var isVerticalPass: Int32
}

/// Gaussian blur effect using Metal compute shader.
/// Performs separable two-pass blur (horizontal then vertical) for efficiency.
final class GaussianBlurMetalEffect: MetalEffect {

    // MARK: - Parameter Specs (source of truth)

    override class var parameterSpecs: [String: ParameterSpec] {
        [
            "radius": .float(default: 10.0, range: 0...100)
        ]
    }

    // MARK: - Properties

    override var name: String { customName ?? "GaussianBlur" }
    private let customName: String?
    override var shaderFunctionName: String { "gaussianBlurKernel" }

    var radius: Float {
        didSet { radius = max(0, min(100, radius)) }
    }

    // MARK: - Init

    init(radius: Float, name: String? = nil) {
        self.radius = max(0, min(100, radius))
        self.customName = name
        super.init()
        setupMetal()
    }

    required convenience init?(params: [String: AnyCodableValue]?) {
        let p = Params(params, specs: Self.parameterSpecs)
        self.init(radius: p.float("radius"))
    }

    // MARK: - Effect Protocol

    override func apply(to image: CIImage, context: inout RenderContext) -> CIImage {
        guard isMetalReady,
              let commandQueue = commandQueue,
              let pipeline = pipelineState else {
            return image
        }

        let extent = image.extent
        let width = Int(extent.width)
        let height = Int(extent.height)
        guard width > 0, height > 0 else { return image }

        // Need 3 buffers for two-pass blur
        ensureBuffers(width: width, height: height, names: ["input", "temp", "output"])
        guard let inBuf = buffer(named: "input"),
              let tmpBuf = buffer(named: "temp"),
              let outBuf = buffer(named: "output"),
              let texture1 = texture(from: inBuf),
              let texture2 = texture(from: tmpBuf),
              let texture3 = texture(from: outBuf) else {
            return image
        }

        render(image, to: inBuf)

        guard let commandBuffer = commandQueue.makeCommandBuffer() else {
            return image
        }

        let (groups, threadsPerGroup) = threadgroupConfig(for: (width, height))

        // Pass 1: Horizontal blur (texture1 -> texture2)
        if let encoder = commandBuffer.makeComputeCommandEncoder() {
            var params = GaussianBlurParamsGPU(
                radius: radius,
                textureWidth: Int32(width),
                textureHeight: Int32(height),
                isVerticalPass: 0
            )
            encoder.setComputePipelineState(pipeline)
            encoder.setTexture(texture1, index: 0)
            encoder.setTexture(texture2, index: 1)
            encoder.setBytes(&params, length: MemoryLayout<GaussianBlurParamsGPU>.stride, index: 0)
            encoder.dispatchThreadgroups(groups, threadsPerThreadgroup: threadsPerGroup)
            encoder.endEncoding()
        }

        // Pass 2: Vertical blur (texture2 -> texture3)
        if let encoder = commandBuffer.makeComputeCommandEncoder() {
            var params = GaussianBlurParamsGPU(
                radius: radius,
                textureWidth: Int32(width),
                textureHeight: Int32(height),
                isVerticalPass: 1
            )
            encoder.setComputePipelineState(pipeline)
            encoder.setTexture(texture2, index: 0)
            encoder.setTexture(texture3, index: 1)
            encoder.setBytes(&params, length: MemoryLayout<GaussianBlurParamsGPU>.stride, index: 0)
            encoder.dispatchThreadgroups(groups, threadsPerThreadgroup: threadsPerGroup)
            encoder.endEncoding()
        }

        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()

        return CIImage(cvPixelBuffer: outBuf)
    }

    override func copy() -> Effect {
        GaussianBlurMetalEffect(radius: radius, name: customName)
    }
}
