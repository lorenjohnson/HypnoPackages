//
//  TemporalSmearEffect.swift
//  Hypnograph
//
//  Smears pixels over time based on motion direction
//  Creates painterly, streaky motion blur
//

import CoreImage
import CoreMedia
import CoreGraphics

/// Temporal smear - directional motion blur based on frame differences
/// Creates painterly streaks in the direction of motion
struct TemporalSmearEffect: Effect {
    var name: String { "Temporal Smear" }

    /// Needs lookback frames of history
    var requiredLookback: Int { lookback + 1 }

    /// Smear intensity (0.0 = subtle, 1.0 = extreme)
    let intensity: Float

    /// How far back to sample for motion
    let lookback: Int

    static var parameterSpecs: [String: ParameterSpec] {
        [
            "intensity": .float(default: 0.6, range: 0...1),
            "lookback": .int(default: 4, range: 1...60)
        ]
    }

    init(intensity: Float, lookback: Int) {
        self.intensity = intensity
        self.lookback = lookback
    }

    init?(params: [String: AnyCodableValue]?) {
        let p = Params(params, specs: Self.parameterSpecs)
        self.init(intensity: p.float("intensity"), lookback: p.int("lookback"))
    }
    
    func apply(to image: CIImage, context: inout RenderContext) -> CIImage {
        // Work with whatever frames are available (preroll fills buffer from frame 1)
        let maxOffset = min(lookback, context.frameBuffer.frameCount - 1)
        guard maxOffset >= 2 else { return image }
        
        guard let prevFrame = context.frameBuffer.previousFrame(offset: maxOffset) else {
            return image
        }
        
        // Create motion blur in direction of temporal change
        // Use motion blur filter with angle derived from frame difference
        guard let motionBlur = CIFilter(name: "CIMotionBlur") else {
            return image
        }
        
        // Calculate approximate motion by comparing regions
        let t = CMTimeGetSeconds(context.time)
        
        // Oscillating angle creates varied smear directions
        let angle = CGFloat(sin(t * 0.5) * .pi)
        let radius = 20.0 * CGFloat(intensity)
        
        motionBlur.setValue(image, forKey: kCIInputImageKey)
        motionBlur.setValue(radius, forKey: kCIInputRadiusKey)
        motionBlur.setValue(angle, forKey: kCIInputAngleKey)
        
        guard var result = motionBlur.outputImage else {
            return image
        }
        
        // Blend with older frame using multiply for richer smearing
        guard let multiplyFilter = CIFilter(name: "CIMultiplyBlendMode") else {
            return result.cropped(to: CGRect(origin: .zero, size: context.outputSize))
        }
        
        // Lighten the old frame before blending
        guard let lighten = CIFilter(name: "CIExposureAdjust") else {
            return result.cropped(to: CGRect(origin: .zero, size: context.outputSize))
        }
        
        lighten.setValue(prevFrame, forKey: kCIInputImageKey)
        lighten.setValue(1.0, forKey: kCIInputEVKey)
        
        if let lightened = lighten.outputImage {
            multiplyFilter.setValue(result, forKey: kCIInputImageKey)
            multiplyFilter.setValue(lightened, forKey: kCIInputBackgroundImageKey)
            
            if let multiplied = multiplyFilter.outputImage {
                // Mix with original based on intensity
                guard let mixFilter = CIFilter(name: "CISourceOverCompositing"),
                      let alphaFilter = CIFilter(name: "CIColorMatrix") else {
                    return result.cropped(to: CGRect(origin: .zero, size: context.outputSize))
                }
                
                alphaFilter.setValue(multiplied, forKey: kCIInputImageKey)
                alphaFilter.setValue(CIVector(x: 1, y: 0, z: 0, w: 0), forKey: "inputRVector")
                alphaFilter.setValue(CIVector(x: 0, y: 1, z: 0, w: 0), forKey: "inputGVector")
                alphaFilter.setValue(CIVector(x: 0, y: 0, z: 1, w: 0), forKey: "inputBVector")
                alphaFilter.setValue(CIVector(x: 0, y: 0, z: 0, w: CGFloat(intensity)), forKey: "inputAVector")
                
                if let transparent = alphaFilter.outputImage {
                    mixFilter.setValue(transparent, forKey: kCIInputImageKey)
                    mixFilter.setValue(result, forKey: kCIInputBackgroundImageKey)
                    
                    if let mixed = mixFilter.outputImage {
                        result = mixed
                    }
                }
            }
        }
        
        return result.cropped(to: CGRect(origin: .zero, size: context.outputSize))
    }
}

