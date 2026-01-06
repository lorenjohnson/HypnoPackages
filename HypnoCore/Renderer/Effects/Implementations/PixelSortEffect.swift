//
//  PixelSortEffect.swift
//  Hypnograph
//
//  Pixel sorting glitch effect - sorts pixels by brightness creating streaky artifacts
//

import CoreImage
import CoreMedia
import CoreGraphics

/// Pixel sorting effect - creates horizontal/vertical streaks by sorting pixels
/// Simulates the aesthetic of Kim Asendorf's pixel sorting algorithm
struct PixelSortEffect: Effect {
    var name: String { "PixelSort" }
    
    static var parameterSpecs: [String: ParameterSpec] {
        ["intensity": .float(default: 0.8, range: 0...1)]
    }

    let intensity: Float

    init(intensity: Float) {
        self.intensity = intensity
    }

    init?(params: [String: AnyCodableValue]?) {
        let p = Params(params, specs: Self.parameterSpecs)
        self.init(intensity: p.float("intensity"))
    }
    
    func apply(to image: CIImage, context: inout RenderContext) -> CIImage {
        let t = CMTimeGetSeconds(context.time)
        
        // Oscillate between horizontal and vertical sorting
        let angle = sin(t * 0.2) * .pi / 2.0
        
        // Rotate image
        let rotated = image.transformed(by: CGAffineTransform(rotationAngle: angle))
        
        // Apply motion blur in one direction (simulates pixel sorting)
        guard let motionBlur = CIFilter(name: "CIMotionBlur") else {
            return image
        }
        
        motionBlur.setValue(rotated, forKey: kCIInputImageKey)
        motionBlur.setValue(50.0 * CGFloat(intensity), forKey: kCIInputRadiusKey)
        motionBlur.setValue(0.0, forKey: kCIInputAngleKey)
        
        guard let blurred = motionBlur.outputImage else {
            return image
        }
        
        // Rotate back
        let rotatedBack = blurred.transformed(by: CGAffineTransform(rotationAngle: -angle))
        
        // Add edge detection to create threshold effect
        guard let edges = CIFilter(name: "CIEdges") else {
            return rotatedBack.cropped(to: CGRect(origin: .zero, size: context.outputSize))
        }
        
        edges.setValue(image, forKey: kCIInputImageKey)
        edges.setValue(5.0 * CGFloat(intensity), forKey: kCIInputIntensityKey)
        
        guard let edgeImage = edges.outputImage else {
            return rotatedBack.cropped(to: CGRect(origin: .zero, size: context.outputSize))
        }
        
        // Use edges as a mask for where to apply sorting
        guard let blendWithMask = CIFilter(name: "CIBlendWithMask") else {
            return rotatedBack.cropped(to: CGRect(origin: .zero, size: context.outputSize))
        }
        
        blendWithMask.setValue(rotatedBack, forKey: kCIInputImageKey)
        blendWithMask.setValue(image, forKey: kCIInputBackgroundImageKey)
        blendWithMask.setValue(edgeImage, forKey: kCIInputMaskImageKey)
        
        guard let result = blendWithMask.outputImage else {
            return image
        }
        
        return result.cropped(to: CGRect(origin: .zero, size: context.outputSize))
    }
}

