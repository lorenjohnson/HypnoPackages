//
//  EffectRegistry.swift
//  Hypnograph
//
//  Registry that maps effect type names to their metatypes.
//  Enables JSON config to instantiate Effect objects by name using init?(params:).
//

import Foundation
import CoreGraphics

/// Parameter range metadata for UI sliders
/// Derived from effect's parameterSpecs
public struct ParameterRange {
    public let min: Double
    public let max: Double
    public let step: Double?

    public init(_ min: Double, _ max: Double, step: Double? = nil) {
        self.min = min
        self.max = max
        self.step = step
    }

    /// Default range for unknown parameters - uses value heuristics
    public static let `default` = ParameterRange(0, 100)

    /// Create from ParameterSpec
    public init(from spec: ParameterSpec) {
        if let range = spec.rangeAsDoubles {
            self.min = range.min
            self.max = range.max
        } else {
            self.min = 0
            self.max = 1
        }
        self.step = spec.step
    }
}

/// Registry of effect types that can be instantiated from config
public enum EffectRegistry {

    // MARK: - Effect Type Mapping

    /// Map of type names to effect metatypes.
    /// Each effect declares its own parameterSpecs and init?(params:) - the effect is the source of truth.
    static let effectTypes: [String: any Effect.Type] = [
        // Core Effects
        "RGBSplitSimpleEffect": RGBSplitSimpleEffect.self,

        // Temporal Effects
        "GhostBlurEffect": GhostBlurEffect.self,
        "HoldFrameEffect": HoldFrameEffect.self,
        "ColorEchoEffect": ColorEchoEffect.self,
        "ColorEchoMetalEffect": ColorEchoMetalEffect.self,
        "FrameDifferenceEffect": FrameDifferenceEffect.self,
        "FeedbackLoopEffect": FeedbackLoopEffect.self,
        "TemporalSmearEffect": TemporalSmearEffect.self,

        // Datamosh
        "DatamoshMetalEffect": DatamoshMetalEffect.self,

        // Visual Effects
        "EdgeDecayEffect": EdgeDecayEffect.self,
        "HueWobbleEffect": HueWobbleEffect.self,
        "PixelSortEffect": PixelSortEffect.self,
        "PosterizeDecayEffect": PosterizeDecayEffect.self,

        // Metal Effects
        "PixelateMetalEffect": PixelateMetalEffect.self,
        "BasicEffect": BasicEffect.self,
        "GaussianBlurMetalEffect": GaussianBlurMetalEffect.self,
        "BlockFreezeMetalEffect": BlockFreezeMetalEffect.self,
        "PixelDriftMetalEffect": PixelDriftMetalEffect.self,
        "GlitchBlocksMetalEffect": GlitchBlocksMetalEffect.self,
        "TimeShuffleMetalEffect": TimeShuffleMetalEffect.self,
        "CompressionMetalEffect": CompressionMetalEffect.self,
        "IFrameCompressEffect": IFrameCompressEffect.self,

        // Color Effects
        "LUTEffect": LUTEffect.self,

        // Source Effects
        "TextOverlayEffect": TextOverlayEffect.self
    ]

    /// Create an Effect from a type name and parameters using init?(params:)
    public static func create(type: String, params: [String: AnyCodableValue]?) -> Effect? {
        guard let effectType = effectTypes[type] else {
            print("⚠️ EffectRegistry: Unknown effect type '\(type)'")
            return nil
        }
        return effectType.init(params: params)
    }

    /// Available single effect types for adding to chains
    public static var availableEffectTypes: [(type: String, displayName: String)] {
        effectTypes.keys
            .sorted()
            .map { type in
                (type: type, displayName: formatEffectTypeName(type))
            }
    }

    /// Format effect type name for display: "FrameDifferenceEffect" -> "Frame Difference"
    public static func formatEffectTypeName(_ type: String) -> String {
        // Remove "Effect" suffix
        var name = type
        if name.hasSuffix("Effect") {
            name = String(name.dropLast(6))
        }

        // Insert spaces before uppercase letters (camelCase to Title Case)
        var result = ""
        for (index, char) in name.enumerated() {
            if char.isUppercase && index > 0 {
                result += " "
            }
            result += String(char)
        }
        return result
    }

    // MARK: - Parameter Specs (from effects)

    /// Get parameter specs for an effect type (from the effect's static property)
    public static func parameterSpecs(for effectTypeName: String) -> [String: ParameterSpec] {
        guard let effectType = effectTypes[effectTypeName] else {
            return [:]
        }
        return effectType.parameterSpecs
    }

    /// Get parameter range for a specific effect type and parameter name
    /// Derived from the effect's parameterSpecs
    public static func range(for effectType: String, param: String) -> ParameterRange? {
        guard let spec = parameterSpecs(for: effectType)[param] else {
            return nil
        }
        return ParameterRange(from: spec)
    }

    /// Get all parameter names for an effect type (in consistent order)
    public static func parameterNames(for effectType: String) -> [String] {
        parameterSpecs(for: effectType).keys.sorted()
    }

    // MARK: - Default Parameters

    /// Get default parameters for an effect type
    /// Derived from the effect's parameterSpecs
    public static func defaults(for effectType: String) -> [String: AnyCodableValue] {
        let specs = parameterSpecs(for: effectType)
        var defaults: [String: AnyCodableValue] = [:]
        for (name, spec) in specs {
            defaults[name] = spec.defaultValue
        }
        return defaults
    }
}
