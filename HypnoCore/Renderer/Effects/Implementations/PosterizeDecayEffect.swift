//
//  PosterizeDecayEffect.swift
//  Hypnograph
//
//  Posterizes with temporal blending for chunky, animated look
//  Colors shift and decay based on previous frames
//

import CoreImage
import CoreMedia
import CoreGraphics

/// Posterize decay - reduces colors and blends with time
/// Creates a chunky, animated poster look with temporal variation
struct PosterizeDecayEffect: Effect {
    var name: String { "Posterize Decay" }

    static var parameterSpecs: [String: ParameterSpec] {
        [
            "levels": .float(default: 6.0, range: 2...32),
            "decayAmount": .float(default: 0.4, range: 0...1)
        ]
    }

    /// Number of color levels (lower = more posterized)
    let levels: Float

    /// How much previous frame influences colors
    let decayAmount: Float

    init(levels: Float, decayAmount: Float) {
        self.levels = levels
        self.decayAmount = decayAmount
    }

    init?(params: [String: AnyCodableValue]?) {
        let p = Params(params, specs: Self.parameterSpecs)
        self.init(levels: p.float("levels"), decayAmount: p.float("decayAmount"))
    }
    
    func apply(to image: CIImage, context: inout RenderContext) -> CIImage {
        // Posterize current frame
        guard let posterize = CIFilter(name: "CIColorPosterize") else {
            return image
        }
        
        posterize.setValue(image, forKey: kCIInputImageKey)
        posterize.setValue(levels, forKey: "inputLevels")
        
        guard var result = posterize.outputImage else {
            return image
        }
        
        // Blend with posterized previous frame for decay effect
        if let prevFrame = context.frameBuffer.previousFrame(offset: 1) {
            guard let prevPoster = CIFilter(name: "CIColorPosterize") else {
                return result.cropped(to: CGRect(origin: .zero, size: context.outputSize))
            }
            
            prevPoster.setValue(prevFrame, forKey: kCIInputImageKey)
            prevPoster.setValue(levels, forKey: "inputLevels")
            
            if let prevPosterized = prevPoster.outputImage {
                // Blend with darken mode for chunky transitions
                guard let darken = CIFilter(name: "CIDarkenBlendMode") else {
                    return result.cropped(to: CGRect(origin: .zero, size: context.outputSize))
                }
                
                darken.setValue(prevPosterized, forKey: kCIInputImageKey)
                darken.setValue(result, forKey: kCIInputBackgroundImageKey)
                
                if let darkened = darken.outputImage {
                    // Mix based on decay amount
                    guard let mix = CIFilter(name: "CISourceOverCompositing"),
                          let alpha = CIFilter(name: "CIColorMatrix") else {
                        return result.cropped(to: CGRect(origin: .zero, size: context.outputSize))
                    }
                    
                    alpha.setValue(darkened, forKey: kCIInputImageKey)
                    alpha.setValue(CIVector(x: 1, y: 0, z: 0, w: 0), forKey: "inputRVector")
                    alpha.setValue(CIVector(x: 0, y: 1, z: 0, w: 0), forKey: "inputGVector")
                    alpha.setValue(CIVector(x: 0, y: 0, z: 1, w: 0), forKey: "inputBVector")
                    alpha.setValue(CIVector(x: 0, y: 0, z: 0, w: CGFloat(decayAmount)), forKey: "inputAVector")
                    
                    if let transparent = alpha.outputImage {
                        mix.setValue(transparent, forKey: kCIInputImageKey)
                        mix.setValue(result, forKey: kCIInputBackgroundImageKey)
                        
                        if let mixed = mix.outputImage {
                            result = mixed
                        }
                    }
                }
            }
        }
        
        return result.cropped(to: CGRect(origin: .zero, size: context.outputSize))
    }
}

