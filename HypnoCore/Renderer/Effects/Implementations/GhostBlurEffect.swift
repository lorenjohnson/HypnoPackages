//
//  GhostBlurEffect.swift
//  Hypnograph
//
//  Gaussian blur ghost trails using frame buffer
//  Creates ethereal, dreamy motion trails with progressive blur
//

import CoreImage
import CoreMedia
import CoreGraphics

/// Ghost blur effect - blurred trails from previous frames
/// Each older frame is more blurred, creating smooth ethereal motion
struct GhostBlurEffect: Effect {

    // MARK: - Parameter Specs (source of truth)

    static var parameterSpecs: [String: ParameterSpec] {
        [
            "intensity": .float(default: 0.5, range: 0...2),
            "trailLength": .int(default: 6, range: 1...60),
            "blurAmount": .double(default: 8.0, range: 0...100)
        ]
    }

    // MARK: - Properties

    var name: String { "Ghost Blur" }

    /// Needs trailLength frames of history
    var requiredLookback: Int { trailLength + 1 }

    /// Overall intensity of the ghosting (0.0 = subtle, 1.0 = heavy)
    let intensity: Float

    /// How many frames back to sample for ghost trails
    let trailLength: Int

    /// Base blur amount (multiplied by frame age)
    let blurAmount: CGFloat

    init(intensity: Float, trailLength: Int, blurAmount: CGFloat) {
        self.intensity = intensity
        self.trailLength = trailLength
        self.blurAmount = blurAmount
    }

    init?(params: [String: AnyCodableValue]?) {
        let p = Params(params, specs: Self.parameterSpecs)
        self.init(intensity: p.float("intensity"), trailLength: p.int("trailLength"), blurAmount: p.cgFloat("blurAmount"))
    }
    
    func apply(to image: CIImage, context: inout RenderContext) -> CIImage {
        // Work with whatever frames are available (preroll fills buffer from frame 1)
        // Gracefully degrade if buffer isn't full yet
        let availableFrames = min(trailLength, context.frameBuffer.frameCount - 1)
        guard availableFrames >= 1 else { return image }
        
        var result = image
        
        // Accumulate blurred ghost frames from oldest to newest
        // Older frames are more blurred and more transparent
        for offset in stride(from: availableFrames, through: 1, by: -1) {
            guard let oldFrame = context.frameBuffer.previousFrame(offset: offset) else { continue }
            
            // Progressive blur - older frames are blurrier
            let frameAge = CGFloat(offset) / CGFloat(availableFrames)
            let frameBlur = blurAmount * frameAge * CGFloat(intensity)
            
            var processedFrame = oldFrame
            
            // Apply gaussian blur
            if frameBlur > 0.5 {
                if let blur = CIFilter(name: "CIGaussianBlur") {
                    blur.setValue(oldFrame, forKey: kCIInputImageKey)
                    blur.setValue(frameBlur, forKey: kCIInputRadiusKey)
                    if let blurred = blur.outputImage {
                        processedFrame = blurred.cropped(to: image.extent)
                    }
                }
            }
            
            // Progressive opacity - older frames are more transparent
            let opacity = CGFloat(intensity) * (1.0 - frameAge) * 0.4
            
            guard let alphaFilter = CIFilter(name: "CIColorMatrix") else { continue }
            alphaFilter.setValue(processedFrame, forKey: kCIInputImageKey)
            alphaFilter.setValue(CIVector(x: 1, y: 0, z: 0, w: 0), forKey: "inputRVector")
            alphaFilter.setValue(CIVector(x: 0, y: 1, z: 0, w: 0), forKey: "inputGVector")
            alphaFilter.setValue(CIVector(x: 0, y: 0, z: 1, w: 0), forKey: "inputBVector")
            alphaFilter.setValue(CIVector(x: 0, y: 0, z: 0, w: opacity), forKey: "inputAVector")
            
            guard let transparentFrame = alphaFilter.outputImage else { continue }
            
            // Composite ghost over result
            guard let composite = CIFilter(name: "CISourceOverCompositing") else { continue }
            composite.setValue(transparentFrame, forKey: kCIInputImageKey)
            composite.setValue(result, forKey: kCIInputBackgroundImageKey)
            
            if let composited = composite.outputImage {
                result = composited
            }
        }
        
        return result.cropped(to: CGRect(origin: .zero, size: context.outputSize))
    }
}

