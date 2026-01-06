//
//  ColorEchoEffect.swift
//  Hypnograph
//
//  Echoes color channels from different points in time
//  Creates psychedelic RGB time-offset trails
//

import CoreImage
import CoreMedia
import CoreGraphics

/// Color echo - each color channel comes from a different point in time
/// Red from now, green from N frames ago, blue from 2N frames ago
/// Uses additive blend with intensity control to prevent white blowout
struct ColorEchoEffect: Effect {

    // MARK: - Parameter Specs (source of truth)

    static var parameterSpecs: [String: ParameterSpec] {
        [
            "channelOffset": .int(default: 4, range: 1...30),
            "intensity": .float(default: 0.85, range: 0.1...1.0)
        ]
    }

    // MARK: - Properties

    private let nameOverride: String?
    var name: String { nameOverride ?? "Color Echo" }

    /// Needs 2x channel offset frames (blue channel is furthest back)
    var requiredLookback: Int { channelOffset * 2 + 1 }

    /// Frame offset between channels
    let channelOffset: Int

    /// Intensity of each channel (lower = less white accumulation)
    let intensity: Float

    init(channelOffset: Int, intensity: Float, name: String? = nil) {
        self.channelOffset = channelOffset
        self.intensity = max(0.1, min(1.0, intensity))
        self.nameOverride = name
    }

    init?(params: [String: AnyCodableValue]?) {
        let p = Params(params, specs: Self.parameterSpecs)
        self.init(channelOffset: p.int("channelOffset"), intensity: p.float("intensity"))
    }

    func apply(to image: CIImage, context: inout RenderContext) -> CIImage {
        // Work with whatever frames are available (preroll fills buffer from frame 1)
        let maxOffset = max(0, context.frameBuffer.frameCount - 1)
        guard maxOffset >= 1 else { return image }  // Need at least 1 frame of history

        let greenOffset = min(channelOffset, maxOffset)
        let blueOffset = min(channelOffset * 2, maxOffset)

        guard let greenFrame = context.frameBuffer.previousFrame(offset: greenOffset),
              let blueFrame = context.frameBuffer.previousFrame(offset: blueOffset) else {
            return image
        }

        // Scale factor for each channel - reduces intensity to prevent white blowout
        // Also apply slight decay to older channels
        let redScale = CGFloat(intensity)
        let greenScale = CGFloat(intensity) * 0.95  // Slight decay for older channel
        let blueScale = CGFloat(intensity) * 0.90   // More decay for oldest channel

        // Extract red from current frame (zero out G and B)
        guard let redFilter = CIFilter(name: "CIColorMatrix") else {
            return image
        }
        redFilter.setValue(image, forKey: kCIInputImageKey)
        redFilter.setValue(CIVector(x: redScale, y: 0, z: 0, w: 0), forKey: "inputRVector")
        redFilter.setValue(CIVector(x: 0, y: 0, z: 0, w: 0), forKey: "inputGVector")
        redFilter.setValue(CIVector(x: 0, y: 0, z: 0, w: 0), forKey: "inputBVector")
        redFilter.setValue(CIVector(x: 0, y: 0, z: 0, w: 1), forKey: "inputAVector")

        // Extract green from offset frame (zero out R and B)
        guard let greenFilter = CIFilter(name: "CIColorMatrix") else {
            return image
        }
        greenFilter.setValue(greenFrame, forKey: kCIInputImageKey)
        greenFilter.setValue(CIVector(x: 0, y: 0, z: 0, w: 0), forKey: "inputRVector")
        greenFilter.setValue(CIVector(x: 0, y: greenScale, z: 0, w: 0), forKey: "inputGVector")
        greenFilter.setValue(CIVector(x: 0, y: 0, z: 0, w: 0), forKey: "inputBVector")
        greenFilter.setValue(CIVector(x: 0, y: 0, z: 0, w: 1), forKey: "inputAVector")

        // Extract blue from further offset frame (zero out R and G)
        guard let blueFilter = CIFilter(name: "CIColorMatrix") else {
            return image
        }
        blueFilter.setValue(blueFrame, forKey: kCIInputImageKey)
        blueFilter.setValue(CIVector(x: 0, y: 0, z: 0, w: 0), forKey: "inputRVector")
        blueFilter.setValue(CIVector(x: 0, y: 0, z: 0, w: 0), forKey: "inputGVector")
        blueFilter.setValue(CIVector(x: 0, y: 0, z: blueScale, w: 0), forKey: "inputBVector")
        blueFilter.setValue(CIVector(x: 0, y: 0, z: 0, w: 1), forKey: "inputAVector")

        guard let red = redFilter.outputImage,
              let green = greenFilter.outputImage,
              let blue = blueFilter.outputImage else {
            return image
        }

        // Use CIAdditionCompositing to combine channels
        // Since each image only has one non-zero channel, addition gives us R+G+B
        // The intensity scaling above prevents this from blowing out to white
        guard let add1 = CIFilter(name: "CIAdditionCompositing"),
              let add2 = CIFilter(name: "CIAdditionCompositing") else {
            return image
        }

        add1.setValue(red, forKey: kCIInputImageKey)
        add1.setValue(green, forKey: kCIInputBackgroundImageKey)

        guard let rg = add1.outputImage else {
            return image
        }

        add2.setValue(rg, forKey: kCIInputImageKey)
        add2.setValue(blue, forKey: kCIInputBackgroundImageKey)

        guard let result = add2.outputImage else {
            return image
        }

        return result.cropped(to: CGRect(origin: .zero, size: context.outputSize))
    }
}

