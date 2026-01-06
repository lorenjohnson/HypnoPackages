//
//  RGBSplitEffect.swift
//  Hypnograph
//
//  RGB channel separation glitch effect
//

import CoreImage
import CoreMedia
import CoreGraphics

/// RGB channel separation effect using CoreImage filters
struct RGBSplitSimpleEffect: Effect {

    // MARK: - Parameter Specs (source of truth)

    static var parameterSpecs: [String: ParameterSpec] {
        [
            "offsetAmount": .float(default: 10.0, range: 0...500),
            "animated": .bool(default: true)
        ]
    }

    // MARK: - Properties

    var name: String { "RGB Split" }

    let offsetAmount: Float
    let animated: Bool

    init(offsetAmount: Float, animated: Bool) {
        self.offsetAmount = offsetAmount
        self.animated = animated
    }

    init?(params: [String: AnyCodableValue]?) {
        let p = Params(params, specs: Self.parameterSpecs)
        self.init(offsetAmount: p.float("offsetAmount"), animated: p.bool("animated"))
    }
    
    func apply(to image: CIImage, context: inout RenderContext) -> CIImage {
        // Calculate offset (animate if enabled)
        var offset = CGFloat(offsetAmount)
        if animated {
            let t = CMTimeGetSeconds(context.time)
            // Multiple overlapping waves at different frequencies for organic motion
            let slow = sin(t * 0.7)                    // Slow drift
            let medium = sin(t * 2.3 + 1.5) * 0.4      // Medium variation
            let fast = sin(t * 7.1 + 3.0) * 0.15       // Fast jitter
            let erratic = sin(t * 13.7 + t * 0.3) * 0.1 // Slightly chaotic

            // Combine waves (stays roughly in -1 to 1 range)
            let combined = slow + medium + fast + erratic

            // Map to 0.1-1.0 range (never fully zero for visibility)
            let phase = (combined + 1.0) * 0.45 + 0.1
            offset *= phase
        }
        
        let extent = image.extent
        
        // Extract individual color channels and shift them
        // Red channel - shift right
        let redTransform = CGAffineTransform(translationX: offset, y: 0)
        let redShifted = image.transformed(by: redTransform)
        
        // Blue channel - shift left
        let blueTransform = CGAffineTransform(translationX: -offset, y: 0)
        let blueShifted = image.transformed(by: blueTransform)
        
        // Use color matrix to extract channels
        guard let redFilter = CIFilter(name: "CIColorMatrix"),
              let blueFilter = CIFilter(name: "CIColorMatrix"),
              let greenFilter = CIFilter(name: "CIColorMatrix") else {
            return image
        }
        
        // Red channel only
        redFilter.setValue(redShifted, forKey: kCIInputImageKey)
        redFilter.setValue(CIVector(x: 1, y: 0, z: 0, w: 0), forKey: "inputRVector")
        redFilter.setValue(CIVector(x: 0, y: 0, z: 0, w: 0), forKey: "inputGVector")
        redFilter.setValue(CIVector(x: 0, y: 0, z: 0, w: 0), forKey: "inputBVector")
        
        // Green channel only (no shift)
        greenFilter.setValue(image, forKey: kCIInputImageKey)
        greenFilter.setValue(CIVector(x: 0, y: 0, z: 0, w: 0), forKey: "inputRVector")
        greenFilter.setValue(CIVector(x: 0, y: 1, z: 0, w: 0), forKey: "inputGVector")
        greenFilter.setValue(CIVector(x: 0, y: 0, z: 0, w: 0), forKey: "inputBVector")
        
        // Blue channel only
        blueFilter.setValue(blueShifted, forKey: kCIInputImageKey)
        blueFilter.setValue(CIVector(x: 0, y: 0, z: 0, w: 0), forKey: "inputRVector")
        blueFilter.setValue(CIVector(x: 0, y: 0, z: 0, w: 0), forKey: "inputGVector")
        blueFilter.setValue(CIVector(x: 0, y: 0, z: 1, w: 0), forKey: "inputBVector")
        
        guard let red = redFilter.outputImage,
              let green = greenFilter.outputImage,
              let blue = blueFilter.outputImage else {
            return image
        }
        
        // Combine channels using addition
        guard let addFilter1 = CIFilter(name: "CIAdditionCompositing"),
              let addFilter2 = CIFilter(name: "CIAdditionCompositing") else {
            return image
        }
        
        // Add red + green
        addFilter1.setValue(red, forKey: kCIInputImageKey)
        addFilter1.setValue(green, forKey: kCIInputBackgroundImageKey)
        
        guard let rg = addFilter1.outputImage else {
            return image
        }
        
        // Add (red+green) + blue
        addFilter2.setValue(blue, forKey: kCIInputImageKey)
        addFilter2.setValue(rg, forKey: kCIInputBackgroundImageKey)
        
        return addFilter2.outputImage?.cropped(to: extent) ?? image
    }
}

