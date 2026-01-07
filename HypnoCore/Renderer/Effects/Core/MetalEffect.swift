//
//  MetalEffect.swift
//  Hypnograph
//
//  Base class for Metal compute shader effects.
//  Provides shared infrastructure for device setup, texture caching,
//  buffer management, and shader dispatch.
//

import Foundation
import CoreImage
import CoreVideo
import Metal

/// Base class for Metal compute shader effects.
/// Handles common boilerplate: device setup, texture cache, buffer management, dispatch.
/// Subclasses override `shaderFunctionName` and `processWithMetal()`.
class MetalEffect: Effect {

    // MARK: - Effect Protocol (override in subclasses)

    var name: String { "Metal Effect" }
    var requiredLookback: Int { 0 }
    class var parameterSpecs: [String: ParameterSpec] { [:] }

    /// Required failable init for Effect protocol conformance.
    required init?(params: [String: AnyCodableValue]?) {
        setupMetal()
        loadShader()
    }

    /// Non-failable init for subclasses to call from their designated initializers.
    /// Subclasses should call `setupMetal()` after setting their properties.
    init() {
        // Subclasses call setupMetal() after initializing their own properties
    }

    // MARK: - Shader Configuration (override in subclasses)

    /// The name of the kernel function in the Metal shader file.
    /// Subclasses must override this.
    var shaderFunctionName: String { fatalError("Subclasses must override shaderFunctionName") }

    // MARK: - Metal Resources (protected)

    private(set) var device: MTLDevice?
    private(set) var commandQueue: MTLCommandQueue?
    private(set) var pipelineState: MTLComputePipelineState?
    private(set) var textureCache: CVMetalTextureCache?

    // MARK: - Buffer Management

    /// Managed pixel buffers - subclasses can request buffers by name
    private var pixelBuffers: [String: CVPixelBuffer] = [:]
    private var currentBufferSize: (width: Int, height: Int) = (0, 0)

    // MARK: - Setup

    /// Call this from subclass designated initializers after setting properties.
    func setupMetal() {
        device = MTLCreateSystemDefaultDevice()
        commandQueue = device?.makeCommandQueue()

        if let device = device {
            var cache: CVMetalTextureCache?
            CVMetalTextureCacheCreate(kCFAllocatorDefault, nil, device, nil, &cache)
            textureCache = cache
        }
    }

    private func loadShader() {
        guard let device = device else {
            print("⚠️ \(type(of: self)): No Metal device")
            return
        }

        do {
            let library = try device.makeDefaultLibrary(bundle: HypnoEffectsBundle.bundle)
            guard let function = library.makeFunction(name: shaderFunctionName) else {
                print("⚠️ \(type(of: self)): Kernel '\(shaderFunctionName)' not found")
                return
            }
            pipelineState = try device.makeComputePipelineState(function: function)
        } catch {
            print("⚠️ \(type(of: self)): Pipeline error: \(error)")
        }
    }

    /// Check if Metal is properly initialized
    var isMetalReady: Bool {
        device != nil && commandQueue != nil && pipelineState != nil
    }

    // MARK: - Buffer Helpers

    /// Ensure pixel buffers exist at the given size. Call at start of apply().
    /// Pass buffer names you need (e.g., "input", "output", "feedback").
    func ensureBuffers(width: Int, height: Int, names: [String]) {
        // Check if size changed
        if currentBufferSize.width == width && currentBufferSize.height == height {
            // Size matches, just ensure all requested buffers exist
            for name in names where pixelBuffers[name] == nil {
                pixelBuffers[name] = createPixelBuffer(width: width, height: height)
            }
            return
        }

        // Size changed - recreate all buffers
        currentBufferSize = (width, height)
        pixelBuffers.removeAll()

        for name in names {
            pixelBuffers[name] = createPixelBuffer(width: width, height: height)
        }
    }

    /// Get a managed pixel buffer by name
    func buffer(named name: String) -> CVPixelBuffer? {
        pixelBuffers[name]
    }

    /// Create a Metal-compatible pixel buffer
    func createPixelBuffer(width: Int, height: Int) -> CVPixelBuffer? {
        let attrs: [String: Any] = [
            kCVPixelBufferMetalCompatibilityKey as String: true,
            kCVPixelBufferIOSurfacePropertiesKey as String: [:]
        ]

        var buffer: CVPixelBuffer?
        CVPixelBufferCreate(kCFAllocatorDefault, width, height,
                           kCVPixelFormatType_32BGRA, attrs as CFDictionary, &buffer)
        return buffer
    }

    /// Convert a CVPixelBuffer to an MTLTexture
    func texture(from buffer: CVPixelBuffer) -> MTLTexture? {
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

    /// Render a CIImage to a pixel buffer
    func render(_ image: CIImage, to buffer: CVPixelBuffer) {
        SharedRenderer.ciContext.render(image, to: buffer, bounds: image.extent,
                                        colorSpace: CGColorSpaceCreateDeviceRGB())
    }

    // MARK: - Dispatch Helpers

    /// Calculate optimal threadgroup configuration for the pipeline
    func threadgroupConfig(for size: (width: Int, height: Int)) -> (groups: MTLSize, threadsPerGroup: MTLSize) {
        guard let pipeline = pipelineState else {
            return (MTLSize(width: 1, height: 1, depth: 1),
                    MTLSize(width: 1, height: 1, depth: 1))
        }

        let threadWidth = pipeline.threadExecutionWidth
        let threadHeight = pipeline.maxTotalThreadsPerThreadgroup / threadWidth
        let threadsPerGroup = MTLSize(width: threadWidth, height: threadHeight, depth: 1)
        let threadgroups = MTLSize(
            width: (size.width + threadWidth - 1) / threadWidth,
            height: (size.height + threadHeight - 1) / threadHeight,
            depth: 1
        )

        return (threadgroups, threadsPerGroup)
    }

    /// Run a compute shader with the given encoder setup closure.
    /// Returns the output as a CIImage from the specified buffer, or the original image on failure.
    func runShader(
        outputBufferName: String,
        fallback: CIImage,
        configure: (MTLComputeCommandEncoder) -> Void
    ) -> CIImage {
        guard let commandQueue = commandQueue,
              let pipeline = pipelineState,
              let commandBuffer = commandQueue.makeCommandBuffer(),
              let encoder = commandBuffer.makeComputeCommandEncoder() else {
            return fallback
        }

        encoder.setComputePipelineState(pipeline)
        configure(encoder)

        let (groups, threadsPerGroup) = threadgroupConfig(for: currentBufferSize)
        encoder.dispatchThreadgroups(groups, threadsPerThreadgroup: threadsPerGroup)
        encoder.endEncoding()

        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()

        guard let outBuf = buffer(named: outputBufferName) else {
            return fallback
        }

        return CIImage(cvPixelBuffer: outBuf)
    }

    // MARK: - Effect Protocol

    func apply(to image: CIImage, context: inout RenderContext) -> CIImage {
        // Subclasses override this
        image
    }

    func reset() {
        pixelBuffers.removeAll()
        currentBufferSize = (0, 0)
    }

    func copy() -> Effect {
        fatalError("Subclasses must override copy()")
    }
}
