//
//  FrameDifferenceEffect.swift
//  Hypnograph
//
//  Shows only the difference between frames - reveals motion as bright areas
//  Static areas become dark/transparent
//

import CoreImage
import CoreMedia
import CoreGraphics

/// Frame difference effect - highlights motion by showing inter-frame differences
/// Great for creating ghostly motion trails on dark backgrounds
struct FrameDifferenceEffect: Effect {

    // MARK: - Parameter Specs (source of truth)

    static var parameterSpecs: [String: ParameterSpec] {
        [
            "sensitivity": .float(default: 0.1, range: 0...1),
            "intensity": .float(default: 1.5, range: 0.5...3.0),
            "originalBlend": .float(default: 0.3, range: 0...1)
        ]
    }

    // MARK: - Properties

    var name: String { "Frame Difference" }

    /// Only needs previous frame for comparison
    var requiredLookback: Int { 2 }

    /// Threshold for motion detection (0 = show all differences, 1 = only large motion)
    let sensitivity: Float

    /// Linear multiplier on the difference (1.0 = normal, 2.0 = 2x brighter)
    let intensity: Float

    /// How much original image to blend back (0.0 = pure difference, 1.0 = mostly original)
    let originalBlend: Float

    init(sensitivity: Float, intensity: Float, originalBlend: Float) {
        self.sensitivity = sensitivity
        self.intensity = intensity
        self.originalBlend = originalBlend
    }

    init?(params: [String: AnyCodableValue]?) {
        let p = Params(params, specs: Self.parameterSpecs)
        self.init(sensitivity: p.float("sensitivity"), intensity: p.float("intensity"), originalBlend: p.float("originalBlend"))
    }

    func apply(to image: CIImage, context: inout RenderContext) -> CIImage {
        guard let prevFrame = context.frameBuffer.previousFrame(offset: 1) else {
            return image
        }

        let extent = image.extent

        // Compute absolute difference between current and previous frame
        guard let diffFilter = CIFilter(name: "CIDifferenceBlendMode") else {
            return image
        }

        diffFilter.setValue(image, forKey: kCIInputImageKey)
        diffFilter.setValue(prevFrame, forKey: kCIInputBackgroundImageKey)

        guard var difference = diffFilter.outputImage else {
            return image
        }

        // Apply threshold to cut low differences (noise/static areas)
        // sensitivity 0 = no threshold, sensitivity 1 = very high threshold
        if sensitivity > 0.01 {
            // Use levels to create a threshold effect
            // Map: values below threshold -> 0, above -> stretched to full range
            let threshold = Double(sensitivity * 0.5)  // Scale sensitivity to reasonable threshold
            if let levels = CIFilter(name: "CIColorClamp") {
                // First subtract the threshold
                if let subtract = CIFilter(name: "CIColorMatrix") {
                    let t = CGFloat(threshold)
                    subtract.setValue(difference, forKey: kCIInputImageKey)
                    subtract.setValue(CIVector(x: 1, y: 0, z: 0, w: 0), forKey: "inputRVector")
                    subtract.setValue(CIVector(x: 0, y: 1, z: 0, w: 0), forKey: "inputGVector")
                    subtract.setValue(CIVector(x: 0, y: 0, z: 1, w: 0), forKey: "inputBVector")
                    subtract.setValue(CIVector(x: 0, y: 0, z: 0, w: 1), forKey: "inputAVector")
                    subtract.setValue(CIVector(x: -t, y: -t, z: -t, w: 0), forKey: "inputBiasVector")

                    if let subtracted = subtract.outputImage {
                        // Clamp to 0-1 (removes negative values from threshold)
                        levels.setValue(subtracted, forKey: kCIInputImageKey)
                        levels.setValue(CIVector(x: 0, y: 0, z: 0, w: 0), forKey: "inputMinComponents")
                        levels.setValue(CIVector(x: 1, y: 1, z: 1, w: 1), forKey: "inputMaxComponents")

                        if let thresholded = levels.outputImage {
                            difference = thresholded
                        }
                    }
                }
            }
        }

        // Apply intensity as a linear multiplier (using ColorMatrix)
        if abs(intensity - 1.0) > 0.01 {
            if let multiply = CIFilter(name: "CIColorMatrix") {
                let i = CGFloat(intensity)
                multiply.setValue(difference, forKey: kCIInputImageKey)
                multiply.setValue(CIVector(x: i, y: 0, z: 0, w: 0), forKey: "inputRVector")
                multiply.setValue(CIVector(x: 0, y: i, z: 0, w: 0), forKey: "inputGVector")
                multiply.setValue(CIVector(x: 0, y: 0, z: i, w: 0), forKey: "inputBVector")
                multiply.setValue(CIVector(x: 0, y: 0, z: 0, w: 1), forKey: "inputAVector")

                if let intensified = multiply.outputImage {
                    difference = intensified
                }
            }

            // Clamp result to prevent blow-out
            if let clamp = CIFilter(name: "CIColorClamp") {
                clamp.setValue(difference, forKey: kCIInputImageKey)
                clamp.setValue(CIVector(x: 0, y: 0, z: 0, w: 0), forKey: "inputMinComponents")
                clamp.setValue(CIVector(x: 1, y: 1, z: 1, w: 1), forKey: "inputMaxComponents")
                if let clamped = clamp.outputImage {
                    difference = clamped
                }
            }
        }

        // Blend original image with the difference
        // originalBlend 0 = pure difference, 1 = mostly original with subtle difference overlay
        if originalBlend > 0.01 {
            if let blendFilter = CIFilter(name: "CISourceOverCompositing") {
                // Make original semi-transparent based on originalBlend
                if let alphaFilter = CIFilter(name: "CIColorMatrix") {
                    alphaFilter.setValue(image, forKey: kCIInputImageKey)
                    alphaFilter.setValue(CIVector(x: 1, y: 0, z: 0, w: 0), forKey: "inputRVector")
                    alphaFilter.setValue(CIVector(x: 0, y: 1, z: 0, w: 0), forKey: "inputGVector")
                    alphaFilter.setValue(CIVector(x: 0, y: 0, z: 1, w: 0), forKey: "inputBVector")
                    alphaFilter.setValue(CIVector(x: 0, y: 0, z: 0, w: CGFloat(originalBlend)), forKey: "inputAVector")

                    if let transparentOriginal = alphaFilter.outputImage {
                        // Composite: transparent original over difference
                        blendFilter.setValue(transparentOriginal, forKey: kCIInputImageKey)
                        blendFilter.setValue(difference, forKey: kCIInputBackgroundImageKey)

                        if let blended = blendFilter.outputImage {
                            return blended.cropped(to: extent)
                        }
                    }
                }
            }
        }

        return difference.cropped(to: extent)
    }
}

