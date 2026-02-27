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

    private struct RegisteredEffectType {
        let type: any Effect.Type
        let runtimeKind: EffectRuntimeKind
        let defaultRequiredLookback: Int
        let usesPersistentState: Bool
        let notes: String?

        init(
            type: any Effect.Type,
            runtimeKind: EffectRuntimeKind,
            defaultRequiredLookback: Int,
            usesPersistentState: Bool = false,
            notes: String? = nil
        ) {
            self.type = type
            self.runtimeKind = runtimeKind
            self.defaultRequiredLookback = defaultRequiredLookback
            self.usesPersistentState = usesPersistentState
            self.notes = notes
        }
    }

    // MARK: - Effect Type Mapping

    /// Map of type names to effect metatypes.
    /// Each effect declares its own parameterSpecs and init?(params:) - the effect is the source of truth.
    private static let effectTypes: [String: RegisteredEffectType] = [
        // Non-runtime exceptions intentionally kept as compiled effects.
        "LUTEffect": RegisteredEffectType(
            type: LUTEffect.self,
            runtimeKind: .coreImage,
            defaultRequiredLookback: 0,
            notes: "CIColorCube LUT application."
        ),

        "TextOverlayEffect": RegisteredEffectType(
            type: TextOverlayEffect.self,
            runtimeKind: .cpuOverlay,
            defaultRequiredLookback: 0,
            usesPersistentState: true,
            notes: "CPU text layout/rasterization overlay."
        )
    ]

    private static func staticRegistration(for type: String) -> RegisteredEffectType? {
        effectTypes[type]
    }

    /// Create an Effect from a type name and parameters using init?(params:)
    public static func create(type: String, params: [String: AnyCodableValue]?) -> Effect? {
        if let registration = staticRegistration(for: type) {
            guard let effect = registration.type.init(params: params) else {
                return nil
            }

            // Transitional migration: every single effect is represented as a pass chain stage.
            // This gives us one runtime composition pattern while we port stage internals to Metal.
            let descriptor = runtimeDescriptor(for: type) ?? EffectRuntimeDescriptor(
                effectType: type,
                displayName: formatEffectTypeName(type),
                runtimeKind: .hybrid,
                requiredLookback: effect.requiredLookback
            )
            return PassChainEffect(name: effect.name, stages: [effect], stageRuntimeDescriptors: [descriptor])
        }

        if let definition = RuntimeMetalEffectLibrary.shared.definition(for: type),
           let effect = RuntimeMetalEffect(definition: definition, params: params) {
            let descriptor = runtimeDescriptor(for: type) ?? EffectRuntimeDescriptor(
                effectType: type,
                displayName: definition.name,
                runtimeKind: definition.runtimeKind,
                requiredLookback: definition.requiredLookback,
                usesPersistentState: definition.usesPersistentState,
                notes: "User/runtime Metal asset."
            )
            return PassChainEffect(name: effect.name, stages: [effect], stageRuntimeDescriptors: [descriptor])
        }

        print("⚠️ EffectRegistry: Unknown effect type '\(type)'")
        return nil
    }

    /// Available single effect types for adding to chains
    public static var availableEffectTypes: [(type: String, displayName: String)] {
        let staticTypes = effectTypes.keys.map { type in
            (type: type, displayName: formatEffectTypeName(type))
        }
        let runtimeTypes = RuntimeMetalEffectLibrary.shared.allDefinitions().map { definition in
            (type: definition.typeName, displayName: definition.name)
        }

        return (staticTypes + runtimeTypes)
            .sorted { lhs, rhs in
                lhs.displayName.localizedCaseInsensitiveCompare(rhs.displayName) == .orderedAscending
            }
    }

    /// Format effect type name for display: "FrameDifferenceEffect" -> "Frame Difference"
    public static func formatEffectTypeName(_ type: String) -> String {
        // Runtime effect types should display their manifest names.
        if let runtime = RuntimeMetalEffectLibrary.shared.definition(for: type) {
            let name = runtime.name.trimmingCharacters(in: .whitespacesAndNewlines)
            if !name.isEmpty {
                return name
            }
        }
        if RuntimeMetalEffectLibrary.isRuntimeType(type) {
            return "Runtime Effect"
        }

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
        if let effectType = staticRegistration(for: effectTypeName) {
            return effectType.type.parameterSpecs
        }
        if let definition = RuntimeMetalEffectLibrary.shared.definition(for: effectTypeName) {
            return definition.parameterSpecs
        }
        return [:]
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
        if let definition = RuntimeMetalEffectLibrary.shared.definition(for: effectType) {
            return definition.parameterOrder
        }
        return parameterSpecs(for: effectType).keys.sorted()
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

    /// Runtime descriptor for a registered effect type (defaults view).
    public static func runtimeDescriptor(for effectType: String) -> EffectRuntimeDescriptor? {
        if let registration = staticRegistration(for: effectType) {
            return EffectRuntimeDescriptor(
                effectType: effectType,
                displayName: formatEffectTypeName(effectType),
                runtimeKind: registration.runtimeKind,
                requiredLookback: registration.defaultRequiredLookback,
                usesPersistentState: registration.usesPersistentState,
                notes: registration.notes
            )
        }

        if let definition = RuntimeMetalEffectLibrary.shared.definition(for: effectType) {
            return EffectRuntimeDescriptor(
                effectType: effectType,
                displayName: definition.name,
                runtimeKind: definition.runtimeKind,
                requiredLookback: definition.requiredLookback,
                usesPersistentState: definition.usesPersistentState,
                notes: "Runtime Metal asset."
            )
        }

        return nil
    }

    /// Runtime descriptors for all registered effect types.
    public static var runtimeDescriptors: [EffectRuntimeDescriptor] {
        let staticDescriptors = effectTypes.keys
            .sorted()
            .compactMap { runtimeDescriptor(for: $0) }
        let runtimeAssetDescriptors = RuntimeMetalEffectLibrary.shared.allDefinitions()
            .compactMap { runtimeDescriptor(for: $0.typeName) }
        return staticDescriptors + runtimeAssetDescriptors
    }
}
