//
//  BlendModes.swift
//  Hypnograph
//
//  Blend mode constants, classification, and normalization strategies.
//
//  Theory: Non-linear blend modes compound exponentially:
//    - Screen: result = 1 - (1-a)(1-b) → pushes toward white
//    - Multiply: result = a * b → pushes toward black
//  Strategies apply per-layer opacity compensation and/or post-composition
//  normalization to maintain stable luminance and contrast.
//

import CoreImage

// MARK: - Blend Mode Constants

/// Namespace for blend mode constants
public enum BlendMode {
    /// Normal source-over compositing
    public static let sourceOver = "CISourceOverCompositing"

    /// Default per-layer blend mode for Montage (above layer 0)
    public static let defaultMontage = "CIScreenBlendMode"

    /// Available blend modes for random selection and cycling
    public static let all: [String] = [
        "CIScreenBlendMode",
        "CIAdditionCompositing",
        "CILinearDodgeBlendMode",
        "CIColorDodgeBlendMode",
        "CILightenBlendMode",
        "CIOverlayBlendMode",
        "CISoftLightBlendMode",
        "CIHardLightBlendMode",
        // "CIVividLightBlendMode",
        "CIPinLightBlendMode",
        "CIMultiplyBlendMode",
        "CIColorBurnBlendMode",
        "CIDarkenBlendMode",
        // "CILinearBurnBlendMode",
    ]

    /// Returns a random blend mode
    public static func random() -> String {
        all.randomElement() ?? defaultMontage
    }
}

// MARK: - Blend Mode Classification

/// Categorizes blend modes by their luminance behavior
public enum BlendModeFamily {
    case lightening  // Screen, ColorDodge, etc. → pushes toward white
    case darkening   // Multiply, ColorBurn, etc. → pushes toward black
    case contrast    // Overlay, SoftLight, etc. → increases contrast
    case neutral     // SourceOver, Normal → no compensation needed
}

/// Maps blend mode names to their family (dictionary lookup)
private let blendModeFamilies: [String: BlendModeFamily] = [
    // Lightening
    "CIScreenBlendMode": .lightening,
    "CIColorDodgeBlendMode": .lightening,
    "CILightenBlendMode": .lightening,
    "CIAdditionCompositing": .lightening,
    "CILinearDodgeBlendMode": .lightening,
    // Darkening
    "CIMultiplyBlendMode": .darkening,
    "CIColorBurnBlendMode": .darkening,
    "CIDarkenBlendMode": .darkening,
    "CILinearBurnBlendMode": .darkening,
    // Contrast
    "CIOverlayBlendMode": .contrast,
    "CISoftLightBlendMode": .contrast,
    "CIHardLightBlendMode": .contrast,
    "CIVividLightBlendMode": .contrast,
    "CIPinLightBlendMode": .contrast,
]

/// Get the family for a blend mode
public func blendModeFamily(for mode: String) -> BlendModeFamily {
    blendModeFamilies[mode] ?? .neutral
}

// MARK: - Blend Mode Analysis

/// Summary of blend mode usage in a composite
public struct BlendModeAnalysis {
    public let layerCount: Int
    public let lighteningCount: Int
    public let darkeningCount: Int
    public let contrastCount: Int

    /// True if there are enough non-neutral layers to warrant compensation
    public var needsCompensation: Bool {
        layerCount >= 3 && (lighteningCount > 0 || darkeningCount > 0)
    }

    /// Dominant drift direction (if any)
    public var dominantFamily: BlendModeFamily? {
        if lighteningCount > darkeningCount && lighteningCount > 0 {
            return .lightening
        } else if darkeningCount > lighteningCount && darkeningCount > 0 {
            return .darkening
        } else if lighteningCount > 0 && darkeningCount > 0 {
            return .contrast  // Mixed
        }
        return nil
    }
}

/// Analyze blend modes to determine the dominant behavior
public func analyzeBlendModes(_ modes: [String]) -> BlendModeAnalysis {
    var lightening = 0
    var darkening = 0
    var contrast = 0

    // Skip first mode (base layer is always SourceOver)
    for mode in modes.dropFirst() {
        switch blendModeFamily(for: mode) {
        case .lightening: lightening += 1
        case .darkening: darkening += 1
        case .contrast: contrast += 1
        case .neutral: break
        }
    }

    return BlendModeAnalysis(
        layerCount: modes.count,
        lighteningCount: lightening,
        darkeningCount: darkening,
        contrastCount: contrast
    )
}

// MARK: - Normalization Strategy Protocol

/// A swappable strategy for blend mode normalization.
public protocol NormalizationStrategy {
    /// Display name for UI/debugging
    var name: String { get }

    /// Per-layer opacity compensation (called before each blend operation)
    func opacityForLayer(
        index: Int,
        totalLayers: Int,
        blendMode: String,
        analysis: BlendModeAnalysis
    ) -> CGFloat

    /// Post-composition normalization (called after all layers are blended)
    func normalizeComposite(_ image: CIImage, analysis: BlendModeAnalysis) -> CIImage
}

// Default implementations
public extension NormalizationStrategy {
    func opacityForLayer(
        index: Int,
        totalLayers: Int,
        blendMode: String,
        analysis: BlendModeAnalysis
    ) -> CGFloat {
        return 1.0  // No per-layer compensation by default
    }

    func normalizeComposite(_ image: CIImage, analysis: BlendModeAnalysis) -> CIImage {
        return image  // No post-processing by default
    }
}

// MARK: - Available Strategies

/// Auto-select best strategy based on blend mode analysis
public func autoSelectNormalization(for analysis: BlendModeAnalysis) -> NormalizationStrategy {
    if !analysis.needsCompensation {
        return NoNormalization()
    }
    return SqrtPlusGammaStrategy()
}

// MARK: - Concrete Strategies

/// No normalization - pass through unchanged
public struct NoNormalization: NormalizationStrategy {
    public var name: String { "None" }
}

/// Per-layer sqrt(n) opacity compensation only
public struct SqrtOpacityStrategy: NormalizationStrategy {
    public var name: String { "Sqrt Opacity" }

    public func opacityForLayer(
        index: Int,
        totalLayers: Int,
        blendMode: String,
        analysis: BlendModeAnalysis
    ) -> CGFloat {
        guard index > 0, totalLayers > 1 else { return 1.0 }

        let family = blendModeFamily(for: blendMode)
        let n = CGFloat(totalLayers)

        switch family {
        case .lightening, .darkening:
            return 1.0 / sqrt(n)
        case .contrast:
            return 1.0 / pow(n, 0.3)
        case .neutral:
            return 1.0
        }
    }
}

/// Post-composition gamma correction only
public struct GammaPostStrategy: NormalizationStrategy {
    public var name: String { "Gamma Post" }

    public func normalizeComposite(_ image: CIImage, analysis: BlendModeAnalysis) -> CIImage {
        guard analysis.needsCompensation else { return image }

        let gamma: Double
        switch analysis.dominantFamily {
        case .lightening:
            gamma = 1.0 + 0.15 * Double(analysis.lighteningCount)
        case .darkening:
            gamma = 1.0 / (1.0 + 0.15 * Double(analysis.darkeningCount))
        case .contrast, .neutral, nil:
            gamma = 1.0 + 0.1 * Double(analysis.layerCount - 2)
        }

        guard let filter = CIFilter(name: "CIGammaAdjust") else { return image }
        filter.setValue(image, forKey: kCIInputImageKey)
        filter.setValue(gamma, forKey: "inputPower")
        return filter.outputImage ?? image
    }
}

/// Hybrid: sqrt opacity + light gamma safety net (recommended default)
public struct SqrtPlusGammaStrategy: NormalizationStrategy {
    public var name: String { "Balanced (Auto)" }

    private let sqrtStrategy = SqrtOpacityStrategy()

    public func opacityForLayer(
        index: Int,
        totalLayers: Int,
        blendMode: String,
        analysis: BlendModeAnalysis
    ) -> CGFloat {
        sqrtStrategy.opacityForLayer(
            index: index,
            totalLayers: totalLayers,
            blendMode: blendMode,
            analysis: analysis
        )
    }

    public func normalizeComposite(_ image: CIImage, analysis: BlendModeAnalysis) -> CIImage {
        guard analysis.needsCompensation else { return image }

        let gamma: Double
        switch analysis.dominantFamily {
        case .lightening:
            gamma = 1.0 + 0.08 * Double(analysis.lighteningCount)
        case .darkening:
            gamma = 1.0 / (1.0 + 0.08 * Double(analysis.darkeningCount))
        case .contrast, .neutral, nil:
            return image
        }

        guard let filter = CIFilter(name: "CIGammaAdjust") else { return image }
        filter.setValue(image, forKey: kCIInputImageKey)
        filter.setValue(gamma, forKey: "inputPower")
        return filter.outputImage ?? image
    }
}
