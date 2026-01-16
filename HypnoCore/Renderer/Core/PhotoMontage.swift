//
//  PhotoMontage.swift
//  Hypnograph
//
//  Composites multiple still images with blend modes and exports as PNG.
//  Reusable for any feature that needs to blend and export photos.
//

import CoreImage
import CoreGraphics
import UniformTypeIdentifiers

/// Composites still images with blend modes and exports the result.
struct PhotoMontage {
    
    /// A layer in the montage
    struct Layer {
        let image: CIImage
        let transform: CGAffineTransform
        let blendMode: String
        
        init(image: CIImage, transform: CGAffineTransform = .identity, blendMode: String = BlendMode.sourceOver) {
            self.image = image
            self.transform = transform
            self.blendMode = blendMode
        }
    }
    
    private let layers: [Layer]
    private let outputSize: CGSize
    private let sourceFraming: SourceFraming
    
    init(layers: [Layer], outputSize: CGSize, sourceFraming: SourceFraming = .fill) {
        self.layers = layers
        self.outputSize = outputSize
        self.sourceFraming = sourceFraming
    }
    
    /// Convenience init from RenderInstruction (for integration with existing pipeline)
    init?(instruction: RenderInstruction, outputSize: CGSize) {
        var layers: [Layer] = []
        for (index, maybeImage) in instruction.stillImages.enumerated() {
            guard let image = maybeImage else { continue }
            let transform = index < instruction.transforms.count ? instruction.transforms[index] : .identity
            let blendMode = index < instruction.blendModes.count ? instruction.blendModes[index] : BlendMode.sourceOver
            layers.append(Layer(image: image, transform: transform, blendMode: blendMode))
        }
        guard !layers.isEmpty else { return nil }
        self.layers = layers
        self.outputSize = outputSize
        self.sourceFraming = instruction.sourceFraming
    }
    
    // MARK: - Composite

    /// Composite all layers into a single image
    /// Uses EffectManager for blend normalization when available
    func composite(manager: EffectManager?) -> CIImage {
        let totalLayers = layers.count

        // Build blend analysis from our layers
        let blendModes = layers.enumerated().map { index, layer in
            index == 0 ? BlendMode.sourceOver : layer.blendMode
        }
        let analysis = analyzeBlendModes(blendModes)
        let strategy = manager?.normalizationStrategy ?? autoSelectNormalization(for: analysis)

        var result = CIImage.empty().cropped(to: CGRect(origin: .zero, size: outputSize))

        for (index, layer) in layers.enumerated() {
            var img = layer.image.transformed(by: layer.transform)
            img = RendererImageUtils.applySourceFraming(image: img, to: outputSize, framing: sourceFraming)

            // First layer uses source-over, subsequent use their blend mode
            if index == 0 {
                result = img
            } else {
                // Get compensated opacity from normalization strategy
                let opacity = strategy.opacityForLayer(
                    index: index,
                    totalLayers: totalLayers,
                    blendMode: layer.blendMode,
                    analysis: analysis
                )
                result = RendererImageUtils.blend(layer: img, over: result, mode: layer.blendMode, opacity: opacity)
            }
        }

        // Apply post-composition normalization
        result = strategy.normalizeComposite(result, analysis: analysis)

        return result.cropped(to: CGRect(origin: .zero, size: outputSize))
    }
    
    // MARK: - Export

    /// Export composited image as PNG
    func exportPNG(to url: URL, manager: EffectManager? = nil) -> Result<URL, Error> {
        let ciContext = CIContext()
        let composited = composite(manager: manager)
        
        guard let cgImage = ciContext.createCGImage(composited, from: composited.extent) else {
            return .failure(NSError(domain: "PhotoMontage", code: 1,
                userInfo: [NSLocalizedDescriptionKey: "Failed to create CGImage"]))
        }
        
        let pngURL = url.deletingPathExtension().appendingPathExtension("png")
        
        guard let destination = CGImageDestinationCreateWithURL(pngURL as CFURL, UTType.png.identifier as CFString, 1, nil) else {
            return .failure(NSError(domain: "PhotoMontage", code: 2,
                userInfo: [NSLocalizedDescriptionKey: "Failed to create image destination"]))
        }
        
        CGImageDestinationAddImage(destination, cgImage, nil)
        
        if CGImageDestinationFinalize(destination) {
            return .success(pngURL)
        } else {
            return .failure(NSError(domain: "PhotoMontage", code: 3,
                userInfo: [NSLocalizedDescriptionKey: "Failed to write PNG"]))
        }
    }
}
