//
//  EdgeDecayEffect.swift
//  Hypnograph
//
//  Emphasizes and decays edges over time
//  Creates a sketchy, dissolving effect
//

import CoreImage
import CoreMedia
import CoreGraphics

/// Edge decay - finds edges and blends them with temporal decay
/// Creates a sketchy, hand-drawn look that dissolves over time
struct EdgeDecayEffect: Effect {
    var name: String { "Edge Decay" }
    
    /// How much edge to blend in (0.0 = subtle, 1.0 = heavy)
    let intensity: Float
    
    static var parameterSpecs: [String: ParameterSpec] {
        ["intensity": .float(default: 0.6, range: 0...1)]
    }

    init(intensity: Float) {
        self.intensity = intensity
    }

    init?(params: [String: AnyCodableValue]?) {
        let p = Params(params, specs: Self.parameterSpecs)
        self.init(intensity: p.float("intensity"))
    }
    
    func apply(to image: CIImage, context: inout RenderContext) -> CIImage {
        // Detect edges
        guard let edges = CIFilter(name: "CIEdges") else {
            return image
        }
        
        edges.setValue(image, forKey: kCIInputImageKey)
        edges.setValue(5.0 * CGFloat(intensity), forKey: kCIInputIntensityKey)
        
        guard let edgeImage = edges.outputImage else {
            return image
        }
        
        var result = image
        
        // Blend edges with previous frame's edges if available
        if let prevFrame = context.frameBuffer.previousFrame(offset: 1) {
            guard let prevEdges = CIFilter(name: "CIEdges") else {
                return image
            }
            
            prevEdges.setValue(prevFrame, forKey: kCIInputImageKey)
            prevEdges.setValue(5.0 * CGFloat(intensity), forKey: kCIInputIntensityKey)
            
            if let prevEdgeImage = prevEdges.outputImage {
                // Screen blend old and new edges for accumulation
                guard let screen = CIFilter(name: "CIScreenBlendMode") else {
                    return image
                }
                
                screen.setValue(edgeImage, forKey: kCIInputImageKey)
                screen.setValue(prevEdgeImage, forKey: kCIInputBackgroundImageKey)
                
                if let accumulatedEdges = screen.outputImage {
                    // Overlay accumulated edges on original
                    guard let overlay = CIFilter(name: "CIOverlayBlendMode") else {
                        return image
                    }
                    
                    overlay.setValue(accumulatedEdges, forKey: kCIInputImageKey)
                    overlay.setValue(result, forKey: kCIInputBackgroundImageKey)
                    
                    if let overlaid = overlay.outputImage {
                        // Reduce saturation for sketchy feel
                        guard let desat = CIFilter(name: "CIColorControls") else {
                            return overlaid.cropped(to: CGRect(origin: .zero, size: context.outputSize))
                        }
                        
                        desat.setValue(overlaid, forKey: kCIInputImageKey)
                        desat.setValue(1.0 - CGFloat(intensity) * 0.5, forKey: kCIInputSaturationKey)
                        desat.setValue(1.0 + CGFloat(intensity) * 0.2, forKey: kCIInputContrastKey)
                        
                        if let final = desat.outputImage {
                            result = final
                        }
                    }
                }
            }
        } else {
            // No previous frame, just overlay current edges
            guard let overlay = CIFilter(name: "CIOverlayBlendMode") else {
                return image
            }
            
            overlay.setValue(edgeImage, forKey: kCIInputImageKey)
            overlay.setValue(result, forKey: kCIInputBackgroundImageKey)
            
            if let overlaid = overlay.outputImage {
                result = overlaid
            }
        }
        
        return result.cropped(to: CGRect(origin: .zero, size: context.outputSize))
    }
}

