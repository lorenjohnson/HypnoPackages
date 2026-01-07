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
final class PixelDriftMetalEffect: MetalEffect {

    // MARK: - Parameter Specs

    override class var parameterSpecs: [String: ParameterSpec] {
        [
            "driftStrength": .float(default: 8.0, range: 1...30),
            "threshold": .float(default: 0.05, range: 0...0.5),
            "decay": .float(default: 0.6, range: 0...1)
        ]
    }

    // MARK: - Properties

    override var name: String { "Pixel Drift" }
    override var requiredLookback: Int { 5 }
    override var shaderFunctionName: String { "pixelDriftKernel" }

    var driftStrength: Float
    var threshold: Float
    var decay: Float

    private var frameCounter: UInt32 = 0

    // MARK: - Init

    init(driftStrength: Float, threshold: Float, decay: Float) {
        self.driftStrength = max(1, min(30, driftStrength))
        self.threshold = max(0, min(0.5, threshold))
        self.decay = max(0, min(1, decay))
        super.init()
        setupMetal()
    }

    required convenience init?(params: [String: AnyCodableValue]?) {
        let p = Params(params, specs: Self.parameterSpecs)
        self.init(driftStrength: p.float("driftStrength"), threshold: p.float("threshold"), decay: p.float("decay"))
    }

    // MARK: - Effect Protocol

    override func apply(to image: CIImage, context: inout RenderContext) -> CIImage {
        frameCounter &+= 1

        guard context.frameBuffer.frameCount >= 2 else { return image }
        guard isMetalReady else { return image }

        let extent = image.extent
        let width = Int(extent.width)
        let height = Int(extent.height)
        guard width > 0, height > 0 else { return image }

        // Get previous frame for motion detection
        guard let previousTexture = context.frameBuffer.texture(atHistoryOffset: 1) else {
            return image
        }

        ensureBuffers(width: width, height: height, names: ["input", "output", "feedback"])
        guard let inBuf = buffer(named: "input"),
              let outBuf = buffer(named: "output"),
              let fbBuf = buffer(named: "feedback"),
              let currentTexture = texture(from: inBuf),
              let outputTexture = texture(from: outBuf),
              let feedbackTexture = texture(from: fbBuf) else {
            return image
        }

        render(image, to: inBuf)

        var gpuParams = PixelDriftParamsGPU(
            textureWidth: Int32(width),
            textureHeight: Int32(height),
            driftStrength: driftStrength,
            threshold: threshold,
            decay: decay,
            randomSeed: frameCounter
        )

        let result = runShader(outputBufferName: "output", fallback: image) { encoder in
            encoder.setTexture(currentTexture, index: 0)
            encoder.setTexture(previousTexture, index: 1)
            encoder.setTexture(feedbackTexture, index: 2)
            encoder.setTexture(outputTexture, index: 3)
            encoder.setBytes(&gpuParams, length: MemoryLayout<PixelDriftParamsGPU>.stride, index: 0)
        }

        // Copy output to feedback for next frame
        if let commandQueue = commandQueue,
           let blitBuffer = commandQueue.makeCommandBuffer(),
           let blitEncoder = blitBuffer.makeBlitCommandEncoder() {
            blitEncoder.copy(from: outputTexture, to: feedbackTexture)
            blitEncoder.endEncoding()
            blitBuffer.commit()
            blitBuffer.waitUntilCompleted()
        }

        return result
    }

    override func reset() {
        super.reset()
        frameCounter = 0
    }

    override func copy() -> Effect {
        PixelDriftMetalEffect(driftStrength: driftStrength, threshold: threshold, decay: decay)
    }
}
