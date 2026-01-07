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
final class ColorEchoMetalEffect: MetalEffect {

    // MARK: - Parameter Specs (source of truth)

    override class var parameterSpecs: [String: ParameterSpec] {
        [
            "channelOffset": .int(default: 4, range: 1...30),
            "intensity": .float(default: 1.0, range: 0.5...1.0)
        ]
    }

    // MARK: - Properties

    override var name: String { customName ?? "Color Echo" }
    private let customName: String?

    /// Needs 2x channel offset frames (blue channel is furthest back)
    override var requiredLookback: Int { channelOffset * 2 + 1 }
    override var shaderFunctionName: String { "colorEchoKernel" }

    let channelOffset: Int
    var intensity: Float

    // MARK: - Init

    init(channelOffset: Int, intensity: Float, name: String? = nil) {
        self.channelOffset = max(1, min(30, channelOffset))
        self.intensity = max(0.5, min(1.0, intensity))
        self.customName = name
        super.init()
        setupMetal()
    }

    required convenience init?(params: [String: AnyCodableValue]?) {
        let p = Params(params, specs: Self.parameterSpecs)
        self.init(channelOffset: p.int("channelOffset"), intensity: p.float("intensity"))
    }

    // MARK: - Effect Protocol

    override func apply(to image: CIImage, context: inout RenderContext) -> CIImage {
        guard isMetalReady else { return image }

        let extent = image.extent
        let width = Int(extent.width)
        let height = Int(extent.height)
        guard width > 0, height > 0 else { return image }

        // Get frame buffer textures
        let maxOffset = max(0, context.frameBuffer.frameCount - 1)
        guard maxOffset >= 1 else { return image }

        let greenOffset = min(channelOffset, maxOffset)
        let blueOffset = min(channelOffset * 2, maxOffset)

        guard let greenTexture = context.frameBuffer.texture(atHistoryOffset: greenOffset),
              let blueTexture = context.frameBuffer.texture(atHistoryOffset: blueOffset) else {
            return image
        }

        ensureBuffers(width: width, height: height, names: ["input", "output"])
        guard let inBuf = buffer(named: "input"),
              let currentTexture = texture(from: inBuf),
              let outputTexture = texture(from: buffer(named: "output")!) else {
            return image
        }

        render(image, to: inBuf)

        var gpuParams = ColorEchoParamsGPU(
            intensity: intensity,
            textureWidth: Int32(width),
            textureHeight: Int32(height)
        )

        return runShader(outputBufferName: "output", fallback: image) { encoder in
            encoder.setTexture(currentTexture, index: 0)
            encoder.setTexture(greenTexture, index: 1)
            encoder.setTexture(blueTexture, index: 2)
            encoder.setTexture(outputTexture, index: 3)
            encoder.setBytes(&gpuParams, length: MemoryLayout<ColorEchoParamsGPU>.stride, index: 0)
        }
    }

    override func copy() -> Effect {
        ColorEchoMetalEffect(channelOffset: channelOffset, intensity: intensity, name: customName)
    }
}
