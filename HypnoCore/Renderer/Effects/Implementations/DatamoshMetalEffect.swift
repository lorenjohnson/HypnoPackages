//
//  DatamoshMetalEffect.swift
//  Hypnograph
//
//  Metal compute shader-based datamosh effect.
//  Simulates codec-style I-frame freeze + P-frame drift using block-based sampling.
//

import Foundation
import CoreImage
import CoreMedia
import Metal
import CoreVideo

/// Metal-based datamosh effect with block sampling from frame history.
/// Uses a compute shader to achieve codec-like drift and smear effects.
final class DatamoshMetalEffect: Effect {

    // MARK: - Parameter Specs (source of truth)

    static var parameterSpecs: [String: ParameterSpec] {
        [
            "minHistoryOffset": .int(default: 15, range: 1...120),
            "maxHistoryOffset": .int(default: 70, range: 2...300),
            "blockSize": .int(default: 10, range: 1...256),
            "blockMoshProbability": .float(default: 0.25, range: 0...1),
            "motionSensitivity": .float(default: 0.85, range: 0...2),
            "updateProbability": .float(default: 0.0, range: 0...1),
            "smearStrength": .float(default: 0.45, range: 0...2),
            "jitterAmount": .float(default: 0.25, range: 0...2),
            "feedbackAmount": .float(default: 0.4, range: 0...1),
            "blockiness": .float(default: 0.0, range: 0...1),
            "burstChance": .float(default: 0.008, range: 0...0.5),
            "minBurstDuration": .int(default: 60, range: 1...600),
            "maxBurstDuration": .int(default: 240, range: 1...1200),
            "cleanFrameChance": .float(default: 0.0, range: 0...0.5),
            "intensityVariation": .float(default: 0.5, range: 0...1)
        ]
    }

    // MARK: - Properties

    var name: String { "Datamosh (Metal)" }

    /// Deep history needed for realistic datamosh (up to maxHistoryOffset)
    var requiredLookback: Int { max(params.maxHistoryOffset, 80) }

    // MARK: - Configuration

    /// Effect parameters
    var params: DatamoshParams

    // MARK: - Metal State

    private let device: MTLDevice?
    private let commandQueue: MTLCommandQueue?
    private var pipelineState: MTLComputePipelineState?

    /// Texture cache for CIImage -> MTLTexture conversion
    private var textureCache: CVMetalTextureCache?

    /// Previous output for feedback (stored as pixel buffer for GPU efficiency)
    private var previousOutputBuffer: CVPixelBuffer?
    private var previousOutputTexture: MTLTexture?

    /// Reusable textures to prevent memory growth during export
    private var reusableInputBuffer: CVPixelBuffer?
    private var reusableOutputTexture: MTLTexture?
    private var reusableFeedbackTexture: MTLTexture?
    private var lastWidth: Int = 0
    private var lastHeight: Int = 0

    /// Frame counter for randomSeed
    private var frameCounter: UInt32 = 0

    // MARK: - Burst State

    /// Whether we're currently in a glitch burst
    /// Smooth intensity modulation (0-1) - continuously varies
    private var smoothIntensity: Float = 0.5

    /// Target intensity we're moving toward
    private var targetIntensity: Float = 0.5

    /// How fast intensity moves toward target (0-1, per frame)
    private var intensitySpeed: Float = 0.01

    /// Frames until we pick a new target
    private var framesUntilNewTarget: Int = 0

    /// Random generator for modulation
    private var modulationRng: UInt64 = 0

    /// Seed that changes occasionally for spatial variation
    private var currentSeed: UInt32 = 0

    /// Frames until seed changes
    private var framesUntilSeedChange: Int = 0

    /// Current history offset (smoothly interpolated)
    private var currentHistoryOffset: Float = 30.0

    /// Target history offset we're moving toward
    private var targetHistoryOffset: Float = 30.0

    /// Frames until we pick a new target offset
    private var framesUntilNewOffset: Int = 0

    /// Current blockiness (smoothly interpolated)
    private var currentBlockiness: Float = 0.0

    /// Target blockiness we're moving toward
    private var targetBlockiness: Float = 0.0

    /// Frames until we pick a new target blockiness
    private var framesUntilNewBlockiness: Int = 0

    // MARK: - Init

    init(params: DatamoshParams = .default) {
        self.params = params

        // Initialize Metal
        self.device = SharedRenderer.metalDevice
        self.commandQueue = device?.makeCommandQueue()

        // Create texture cache
        if let device = device {
            var cache: CVMetalTextureCache?
            CVMetalTextureCacheCreate(kCFAllocatorDefault, nil, device, nil, &cache)
            self.textureCache = cache
        }

        // Load compute shader
        loadShader()
    }

    required convenience init?(params: [String: AnyCodableValue]?) {
        let p = Params(params, specs: Self.parameterSpecs)
        let datamoshParams = DatamoshParams(
            minHistoryOffset: p.int("minHistoryOffset"),
            maxHistoryOffset: p.int("maxHistoryOffset"),
            freezeReference: params?["freezeReference"]?.boolValue ?? false,
            frozenHistoryOffset: params?["frozenHistoryOffset"]?.intValue,
            blockSize: p.int("blockSize"),
            blockMoshProbability: p.float("blockMoshProbability"),
            motionSensitivity: p.float("motionSensitivity"),
            updateProbability: p.float("updateProbability"),
            smearStrength: p.float("smearStrength"),
            jitterAmount: p.float("jitterAmount"),
            feedbackAmount: p.float("feedbackAmount"),
            blockiness: p.float("blockiness"),
            burstChance: p.float("burstChance"),
            minBurstDuration: p.int("minBurstDuration"),
            maxBurstDuration: p.int("maxBurstDuration"),
            cleanFrameChance: p.float("cleanFrameChance"),
            intensityVariation: p.float("intensityVariation"),
            randomSeed: UInt32(params?["randomSeed"]?.intValue ?? 0)
        )
        self.init(params: datamoshParams)
    }

    private func loadShader() {
        guard let device = device else {
            print("⚠️ DatamoshMetalEffect: No Metal device")
            return
        }

        do {
            let library = try device.makeDefaultLibrary(bundle: HypnoEffectsBundle.bundle)
            guard let function = library.makeFunction(name: "datamoshKernel") else {
                print("⚠️ DatamoshMetalEffect: Kernel function not found")
                return
            }
            pipelineState = try device.makeComputePipelineState(function: function)
        } catch {
            print("⚠️ DatamoshMetalEffect: Failed to create pipeline: \(error)")
        }
    }

    // MARK: - Effect Protocol

    func apply(to image: CIImage, context: inout RenderContext) -> CIImage {
        frameCounter &+= 1

        // Update smooth intensity modulation
        updateIntensityModulation()

        // Need minimum history (but in looping mode, just need 1 frame - buffer will wrap)
        let bufferCount = context.frameBuffer.frameCount
        let requiredFrames = FrameBuffer.loopingModeEnabled ? 1 : params.minHistoryOffset
        guard bufferCount >= requiredFrames else {
            if frameCounter % 30 == 0 {  // Log once per second
                print("⏳ Datamosh waiting for frames: \(bufferCount)/\(requiredFrames)")
            }
            return image
        }

        // Need Metal
        guard device != nil,
              let commandQueue = commandQueue,
              let pipeline = pipelineState else {
            return image
        }

        let extent = image.extent
        let width = Int(extent.width)
        let height = Int(extent.height)

        guard width > 0, height > 0 else { return image }

        // Convert current frame to texture
        guard let currentTexture = createTexture(from: image, width: width, height: height) else {
            return image
        }

        // Get history texture
        let historyOffset = selectHistoryOffset()
        guard let historyTexture = context.frameBuffer.texture(atHistoryOffset: historyOffset) else {
            return image
        }

        // Get or create previous output texture for feedback
        let feedbackTexture = getPreviousOutputTexture(width: width, height: height)

        // Create output texture
        guard let outputTexture = createOutputTexture(width: width, height: height) else {
            return image
        }

        // Use smooth intensity modulation - but keep a strong baseline
        // Scale from 0.6 to 1.0 so effect is always visible
        let effectIntensity = 0.6 + smoothIntensity * 0.4

        // Apply intensity to params - but don't reduce base effect too much
        var modParams = params
        // Keep at least 70% of base displacement
        modParams.blockMoshProbability = params.blockMoshProbability * (0.7 + effectIntensity * 0.3)
        // smearStrength: keep close to param value
        modParams.smearStrength = params.smearStrength + (1.0 - effectIntensity) * 0.15
        modParams.feedbackAmount = params.feedbackAmount * effectIntensity
        // Use modulated blockiness (can vary between fluid and blocky over time)
        modParams.blockiness = currentBlockiness

        // Setup GPU params
        var gpuParams = DatamoshParamsGPU(from: modParams, width: width, height: height)
        gpuParams.randomSeed = currentSeed

        // Run compute shader
        guard let commandBuffer = commandQueue.makeCommandBuffer(),
              let encoder = commandBuffer.makeComputeCommandEncoder() else {
            return image
        }

        encoder.setComputePipelineState(pipeline)
        encoder.setTexture(currentTexture, index: 0)
        encoder.setTexture(historyTexture, index: 1)
        encoder.setTexture(feedbackTexture ?? currentTexture, index: 2)  // Fallback if no feedback
        encoder.setTexture(outputTexture, index: 3)
        encoder.setBytes(&gpuParams, length: MemoryLayout<DatamoshParamsGPU>.stride, index: 0)

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

        // Store output for feedback
        storeFeedbackTexture(outputTexture, width: width, height: height)

        // Convert back to CIImage (flip Y to match CIImage coordinate system)
        guard let outputImage = CIImage(mtlTexture: outputTexture, options: [.colorSpace: CGColorSpaceCreateDeviceRGB()]) else {
            return image
        }

        // Metal has origin top-left, CIImage has origin bottom-left - flip it
        let flipped = outputImage.transformed(by: CGAffineTransform(scaleX: 1, y: -1)
            .translatedBy(x: 0, y: -outputImage.extent.height))

        return flipped
    }

    func reset() {
        print("🔄 DatamoshMetalEffect: reset() called - clearing all state")
        frameCounter = 0
        previousOutputBuffer = nil
        previousOutputTexture = nil
        // Clear reusable buffers to free memory
        reusableInputBuffer = nil
        reusableOutputTexture = nil
        reusableFeedbackTexture = nil
        lastWidth = 0
        lastHeight = 0
        // Reset modulation state
        smoothIntensity = 0.5
        targetIntensity = 0.5
        framesUntilNewTarget = 0
        modulationRng = UInt64.random(in: 0...UInt64.max)
        currentSeed = 0
        framesUntilSeedChange = 0
        // Reset history offset to middle of range
        let midOffset = Float(params.minHistoryOffset + params.maxHistoryOffset) / 2.0
        currentHistoryOffset = midOffset
        targetHistoryOffset = midOffset
        framesUntilNewOffset = 0
        // Reset blockiness
        currentBlockiness = params.blockiness
        targetBlockiness = params.blockiness
        framesUntilNewBlockiness = 0
    }

    func copy() -> Effect {
        // Return a fresh instance with same params but reset state
        return DatamoshMetalEffect(params: params)
    }

    // MARK: - Smooth Temporal Modulation

    /// Update smooth modulation - intensity, history offset, and seed all change slowly over time
    private func updateIntensityModulation() {
        // Move intensity toward target (very slowly)
        let intensityDelta = targetIntensity - smoothIntensity
        smoothIntensity += intensityDelta * intensitySpeed

        // Move history offset toward target (slowly)
        let offsetDelta = targetHistoryOffset - currentHistoryOffset
        currentHistoryOffset += offsetDelta * 0.02  // Smooth interpolation

        // Countdown to new intensity target
        framesUntilNewTarget -= 1
        if framesUntilNewTarget <= 0 {
            // Pick new random target intensity (0.4 to 1.0 range - always visible)
            targetIntensity = 0.4 + nextRandom() * 0.6

            // Pick new duration (3-12 seconds at 30fps)
            framesUntilNewTarget = 90 + Int(nextRandom() * 270)

            // Pick new speed (slower = smoother transitions)
            intensitySpeed = 0.003 + nextRandom() * 0.015  // 0.003 - 0.018
        }

        // Countdown to new history offset target (changes less often)
        framesUntilNewOffset -= 1
        if framesUntilNewOffset <= 0 {
            // Pick new target within params range
            let range = Float(params.maxHistoryOffset - params.minHistoryOffset)
            targetHistoryOffset = Float(params.minHistoryOffset) + nextRandom() * range

            // Change offset target every 5-15 seconds
            framesUntilNewOffset = 150 + Int(nextRandom() * 300)
        }

        // Change seed very rarely for subtle spatial variation
        framesUntilSeedChange -= 1
        if framesUntilSeedChange <= 0 {
            currentSeed = UInt32(truncatingIfNeeded: modulationRng >> 16)
            framesUntilSeedChange = 180 + Int(nextRandom() * 360)  // 6-18 seconds
        }

        // Move blockiness toward target (slowly)
        let blockinessDelta = targetBlockiness - currentBlockiness
        currentBlockiness += blockinessDelta * 0.015  // Smooth transition

        // Countdown to new blockiness target (if base blockiness > 0, otherwise stay fluid)
        if params.blockiness > 0.0 {
            framesUntilNewBlockiness -= 1
            if framesUntilNewBlockiness <= 0 {
                // Sometimes go full blocky, sometimes fluid, mostly in between
                let roll = nextRandom()
                if roll < 0.25 {
                    targetBlockiness = 0.0  // Go fluid
                } else if roll > 0.85 {
                    targetBlockiness = params.blockiness * 1.3  // Go extra blocky
                } else {
                    targetBlockiness = params.blockiness * (0.5 + nextRandom() * 0.7)
                }
                targetBlockiness = min(targetBlockiness, 1.0)

                // Change blockiness every 4-12 seconds
                framesUntilNewBlockiness = 120 + Int(nextRandom() * 240)
            }
        }
    }

    /// Get next random value (0-1) using simple LCG
    private func nextRandom() -> Float {
        modulationRng = modulationRng &* 6364136223846793005 &+ 1442695040888963407
        return Float((modulationRng >> 33) & 0x7FFFFFFF) / Float(0x7FFFFFFF)
    }

    /// Linear interpolation helper
    private func lerp(_ a: Float, _ b: Float, _ t: Float) -> Float {
        return a + (b - a) * t
    }

    // MARK: - History Selection

    /// Select which history offset to use - uses smoothly interpolated value
    private func selectHistoryOffset() -> Int {
        if params.freezeReference, let frozen = params.frozenHistoryOffset {
            return frozen
        }

        // Use the smoothly interpolated offset (clamped to valid range)
        let offset = Int(currentHistoryOffset.rounded())
        return max(params.minHistoryOffset, min(offset, params.maxHistoryOffset))
    }

    // MARK: - Texture Helpers

    /// Ensure reusable buffers exist for given size
    private func ensureReusableBuffers(width: Int, height: Int) {
        // Only recreate if size changed
        guard width != lastWidth || height != lastHeight else { return }

        lastWidth = width
        lastHeight = height

        // Create reusable input buffer
        let attrs: [String: Any] = [
            kCVPixelBufferWidthKey as String: width,
            kCVPixelBufferHeightKey as String: height,
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferIOSurfacePropertiesKey as String: [:],
            kCVPixelBufferMetalCompatibilityKey as String: true
        ]
        CVPixelBufferCreate(kCFAllocatorDefault, width, height,
                           kCVPixelFormatType_32BGRA, attrs as CFDictionary, &reusableInputBuffer)

        // Create reusable output texture
        if let device = device {
            let descriptor = MTLTextureDescriptor.texture2DDescriptor(
                pixelFormat: .bgra8Unorm,
                width: width,
                height: height,
                mipmapped: false
            )
            descriptor.usage = [.shaderRead, .shaderWrite, .renderTarget]
            descriptor.storageMode = .shared
            reusableOutputTexture = device.makeTexture(descriptor: descriptor)

            // Create reusable feedback texture
            descriptor.storageMode = .shared
            reusableFeedbackTexture = device.makeTexture(descriptor: descriptor)
        }

        // Clear old feedback
        previousOutputTexture = nil
    }

    /// Create MTLTexture from CIImage (reuses buffer)
    private func createTexture(from image: CIImage, width: Int, height: Int) -> MTLTexture? {
        guard device != nil else { return nil }

        ensureReusableBuffers(width: width, height: height)

        guard let buffer = reusableInputBuffer else { return nil }

        // Render CIImage to reusable buffer
        SharedRenderer.ciContext.render(
            image,
            to: buffer,
            bounds: image.extent,
            colorSpace: CGColorSpaceCreateDeviceRGB()
        )

        // Convert to texture
        return textureFromPixelBuffer(buffer)
    }

    /// Get output texture for compute shader (reuses texture)
    private func createOutputTexture(width: Int, height: Int) -> MTLTexture? {
        ensureReusableBuffers(width: width, height: height)
        return reusableOutputTexture
    }

    /// Convert CVPixelBuffer to MTLTexture
    private func textureFromPixelBuffer(_ pixelBuffer: CVPixelBuffer) -> MTLTexture? {
        guard let cache = textureCache else { return nil }

        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)

        var cvTexture: CVMetalTexture?
        let status = CVMetalTextureCacheCreateTextureFromImage(
            kCFAllocatorDefault,
            cache,
            pixelBuffer,
            nil,
            .bgra8Unorm,
            width,
            height,
            0,
            &cvTexture
        )

        guard status == kCVReturnSuccess, let tex = cvTexture else { return nil }
        return CVMetalTextureGetTexture(tex)
    }

    /// Get previous output texture for feedback
    private func getPreviousOutputTexture(width: Int, height: Int) -> MTLTexture? {
        // Check if we have a cached texture of the right size
        if let tex = previousOutputTexture,
           tex.width == width,
           tex.height == height {
            return tex
        }
        return nil
    }

    /// Store output for next frame's feedback (reuses texture)
    private func storeFeedbackTexture(_ texture: MTLTexture, width: Int, height: Int) {
        guard params.feedbackAmount > 0 else {
            previousOutputTexture = nil
            return
        }

        // Ensure we have reusable feedback texture
        ensureReusableBuffers(width: width, height: height)

        guard let feedbackDest = reusableFeedbackTexture,
              let commandBuffer = commandQueue?.makeCommandBuffer(),
              let blitEncoder = commandBuffer.makeBlitCommandEncoder() else {
            return
        }

        // Copy output to reusable feedback texture
        blitEncoder.copy(from: texture,
                        sourceSlice: 0,
                        sourceLevel: 0,
                        sourceOrigin: MTLOrigin(x: 0, y: 0, z: 0),
                        sourceSize: MTLSize(width: width, height: height, depth: 1),
                        to: feedbackDest,
                        destinationSlice: 0,
                        destinationLevel: 0,
                        destinationOrigin: MTLOrigin(x: 0, y: 0, z: 0))
        blitEncoder.endEncoding()
        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()

        previousOutputTexture = feedbackDest
    }
}

