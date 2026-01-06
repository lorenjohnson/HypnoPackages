//
//  Effect.swift
//  Hypnograph
//
//  Core Effect protocol and parameter extraction helper.
//  Effects are pure functions over (context, image) → image.
//  Extracted from RenderHooks.swift as part of effects architecture refactor.
//

import CoreImage

/// Effects: pure functions over (context, image) → image.
/// Apply visual transformations to frames during rendering.
public protocol Effect {
    /// Display name for UI
    var name: String { get }

    /// Number of past frames this effect needs access to.
    /// Used for buffer sizing and effect filtering by capability.
    ///
    /// Guidelines:
    /// - 0: No temporal dependency (pure per-frame effects)
    /// - 1-10: Simple temporal effects (frame diff, hold frame)
    /// - 10-40: Ghost trails, smear, basic datamosh
    /// - 40-120: Advanced datamosh, block propagation, AI effects
    var requiredLookback: Int { get }

    /// Parameter metadata - defines what parameters this effect accepts,
    /// their types, ranges, and default values. Effect is the source of truth.
    static var parameterSpecs: [String: ParameterSpec] { get }

    /// Create an instance from a parameters dictionary.
    /// Each effect extracts its own parameters using parameterSpecs defaults as fallback.
    /// Returns nil if the effect cannot be created (e.g., missing Metal device).
    init?(params: [String: AnyCodableValue]?)

    /// Apply effect to the current frame
    func apply(to image: CIImage, context: inout RenderContext) -> CIImage

    /// Reset internal state (call when switching montages/effects)
    func reset()

    /// Create a fresh copy of this effect with the same configuration but reset state.
    /// Used for export to avoid sharing mutable state with preview.
    /// Stateless effects can return self. Class-based stateful effects MUST return a fresh instance.
    func copy() -> Effect
}

extension Effect {
    /// Default: no lookback required (pure per-frame effect)
    var requiredLookback: Int { 0 }

    /// Default: no parameters
    static var parameterSpecs: [String: ParameterSpec] { [:] }

    func apply(to image: CIImage, context: inout RenderContext) -> CIImage {
        image
    }

    func reset() {
        // Default: no-op for stateless effects
    }

    func copy() -> Effect {
        // Default: return self (for struct-based stateless effects)
        // Class-based stateful effects MUST override this to return a fresh instance
        return self
    }
}

// MARK: - Parameter Extraction Helper

/// Helper for extracting parameter values with defaults from parameterSpecs.
/// Eliminates redundant default value specifications in init?(params:).
struct Params {
    private let dict: [String: AnyCodableValue]?
    private let specs: [String: ParameterSpec]

    init(_ params: [String: AnyCodableValue]?, specs: [String: ParameterSpec]) {
        self.dict = params
        self.specs = specs
    }

    /// Get Float value, falling back to spec default
    func float(_ key: String) -> Float {
        if let value = dict?[key]?.floatValue { return value }
        if case .float(let d, _) = specs[key] { return d }
        return 0
    }

    /// Get Double value, falling back to spec default
    func double(_ key: String) -> Double {
        if let value = dict?[key]?.doubleValue { return value }
        if case .double(let d, _) = specs[key] { return d }
        return 0
    }

    /// Get Int value, falling back to spec default
    func int(_ key: String) -> Int {
        if let value = dict?[key]?.intValue { return value }
        if case .int(let d, _) = specs[key] { return d }
        return 0
    }

    /// Get Bool value, falling back to spec default
    func bool(_ key: String) -> Bool {
        if let value = dict?[key]?.boolValue { return value }
        if case .bool(let d) = specs[key] { return d }
        return false
    }

    /// Get String value (for choice params), falling back to spec default
    func string(_ key: String) -> String {
        if let value = dict?[key]?.stringValue { return value }
        if case .choice(let d, _) = specs[key] { return d }
        if case .color(let d) = specs[key] { return d }
        return ""
    }

    /// Get CGFloat value (from double spec), falling back to spec default
    func cgFloat(_ key: String) -> CGFloat {
        CGFloat(double(key))
    }
}

