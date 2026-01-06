//
//  FeedbackLoopEffect.swift
//  Hypnograph
//
//  Creates video feedback loop effect - like pointing a camera at its own monitor
//  Scales, rotates and blends previous frame back in
//

import CoreImage
import CoreMedia
import CoreGraphics

/// Feedback loop - simulates analog video feedback
/// Scales down and rotates previous frame, blends with current
struct FeedbackLoopEffect: Effect {

    // MARK: - Parameter Specs (source of truth)

    static var parameterSpecs: [String: ParameterSpec] {
        [
            "scale": .double(default: 0.95, range: 0.1...3.0),
            "rotation": .double(default: 0.01, range: -1.0...1.0),
            "intensity": .float(default: 0.5, range: 0...1)
        ]
    }

    // MARK: - Properties

    var name: String { "Feedback Loop" }

    /// How much to scale down the feedback (0.9 = subtle zoom, 0.5 = aggressive)
    let scale: CGFloat

    /// Rotation per frame in radians
    let rotation: CGFloat

    /// Blend amount of feedback
    let intensity: Float

    init(scale: CGFloat, rotation: CGFloat, intensity: Float) {
        self.scale = scale
        self.rotation = rotation
        self.intensity = intensity
    }

    init?(params: [String: AnyCodableValue]?) {
        let p = Params(params, specs: Self.parameterSpecs)
        self.init(scale: p.cgFloat("scale"), rotation: p.cgFloat("rotation"), intensity: p.float("intensity"))
    }
    
    func apply(to image: CIImage, context: inout RenderContext) -> CIImage {
        guard let prevFrame = context.frameBuffer.previousFrame(offset: 1) else {
            return image
        }
        
        let size = context.outputSize
        let centerX = size.width / 2
        let centerY = size.height / 2
        
        // Create transform: translate to center, scale, rotate, translate back
        var transform = CGAffineTransform.identity
        transform = transform.translatedBy(x: centerX, y: centerY)
        transform = transform.scaledBy(x: scale, y: scale)
        transform = transform.rotated(by: rotation)
        transform = transform.translatedBy(x: -centerX, y: -centerY)
        
        var feedback = prevFrame.transformed(by: transform)
        
        // Crop to output size
        feedback = feedback.cropped(to: CGRect(origin: .zero, size: size))
        
        // Slight color shift for analog feel
        if let colorShift = CIFilter(name: "CIHueAdjust") {
            colorShift.setValue(feedback, forKey: kCIInputImageKey)
            colorShift.setValue(0.02, forKey: kCIInputAngleKey)
            if let shifted = colorShift.outputImage {
                feedback = shifted
            }
        }
        
        // Blend feedback with current frame
        guard let alpha = CIFilter(name: "CIColorMatrix"),
              let blend = CIFilter(name: "CISourceOverCompositing") else {
            return image
        }
        
        alpha.setValue(feedback, forKey: kCIInputImageKey)
        alpha.setValue(CIVector(x: 1, y: 0, z: 0, w: 0), forKey: "inputRVector")
        alpha.setValue(CIVector(x: 0, y: 1, z: 0, w: 0), forKey: "inputGVector")
        alpha.setValue(CIVector(x: 0, y: 0, z: 1, w: 0), forKey: "inputBVector")
        alpha.setValue(CIVector(x: 0, y: 0, z: 0, w: CGFloat(intensity)), forKey: "inputAVector")
        
        guard let transparentFeedback = alpha.outputImage else {
            return image
        }
        
        blend.setValue(transparentFeedback, forKey: kCIInputImageKey)
        blend.setValue(image, forKey: kCIInputBackgroundImageKey)
        
        guard let result = blend.outputImage else {
            return image
        }
        
        return result.cropped(to: CGRect(origin: .zero, size: size))
    }
}

