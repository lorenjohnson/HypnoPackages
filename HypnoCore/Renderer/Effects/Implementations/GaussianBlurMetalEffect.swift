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
final class GaussianBlurMetalEffect: Effect {

    // MARK: - Parameter Specs (source of truth)

    static var parameterSpecs: [String: ParameterSpec] {
        [
            "radius": .float(default: 10.0, range: 0...100)
        ]
    }

    // MARK: - Properties

    var name: String { customName ?? "GaussianBlur" }
    private let customName: String?

    var radius: Float {
        didSet { radius = max(0, min(100, radius)) }
    }

    // Metal resources
    private let device: MTLDevice?
    private let commandQueue: MTLCommandQueue?
    private var pipelineState: MTLComputePipelineState?
    private var textureCache: CVMetalTextureCache?

    // Reusable buffers
    private var inputBuffer: CVPixelBuffer?
    private var tempBuffer: CVPixelBuffer?
    private var outputBuffer: CVPixelBuffer?

    // MARK: - Init

    init(radius: Float, name: String? = nil) {
        self.radius = max(0, min(100, radius))
        self.customName = name
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
        self.init(radius: p.float("radius"))
    }

    private func loadShader() {
        guard let device = device else {
            print("⚠️ GaussianBlurMetalEffect: No Metal device")
            return
        }

        do {
            let library = try device.makeDefaultLibrary(bundle: HypnoEffectsBundle.bundle)
            guard let function = library.makeFunction(name: "gaussianBlurKernel") else {
                print("⚠️ GaussianBlurMetalEffect: Kernel function not found")
                return
            }
            pipelineState = try device.makeComputePipelineState(function: function)
        } catch {
            print("⚠️ GaussianBlurMetalEffect: Failed to create pipeline: \(error)")
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
                           kCVPixelFormatType_32BGRA, attrs as CFDictionary, &tempBuffer)
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

        // Ensure buffers
        ensureBuffers(width: width, height: height)
        guard let inBuf = inputBuffer, let tmpBuf = tempBuffer, let outBuf = outputBuffer else {
            return image
        }

        // Render CIImage to input buffer
        SharedRenderer.ciContext.render(image, to: inBuf, bounds: extent,
                                        colorSpace: CGColorSpaceCreateDeviceRGB())

        // Get textures
        guard let texture1 = textureFromBuffer(inBuf),
              let texture2 = textureFromBuffer(tmpBuf),
              let texture3 = textureFromBuffer(outBuf) else {
            return image
        }

        guard let commandBuffer = commandQueue.makeCommandBuffer() else {
            return image
        }

        let threadWidth = pipeline.threadExecutionWidth
        let threadHeight = pipeline.maxTotalThreadsPerThreadgroup / threadWidth
        let threadsPerGroup = MTLSize(width: threadWidth, height: threadHeight, depth: 1)
        let threadgroups = MTLSize(
            width: (width + threadWidth - 1) / threadWidth,
            height: (height + threadHeight - 1) / threadHeight,
            depth: 1
        )

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
            encoder.dispatchThreadgroups(threadgroups, threadsPerThreadgroup: threadsPerGroup)
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
            encoder.dispatchThreadgroups(threadgroups, threadsPerThreadgroup: threadsPerGroup)
            encoder.endEncoding()
        }

        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()

        // Convert output buffer back to CIImage (no orientation flip needed)
        return CIImage(cvPixelBuffer: outBuf)
    }

    func reset() {
        inputBuffer = nil
        tempBuffer = nil
        outputBuffer = nil
    }

    func copy() -> Effect {
        GaussianBlurMetalEffect(radius: radius, name: customName)
    }
}

