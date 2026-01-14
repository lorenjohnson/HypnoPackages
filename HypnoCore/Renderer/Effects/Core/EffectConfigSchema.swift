//
//  EffectConfigSchema.swift
//  Hypnograph
//
//  Codable schema for effects. Two main types:
//  - EffectChain: A named container for 0-n effects (stored in recipe, per layer)
//  - EffectDefinition: A single effect with type + params
//

import Foundation
import CoreImage
import CryptoKit

// MARK: - Core Types

/// An effect chain containing 0-n effects applied in sequence.
/// This is the top-level effect container stored on recipes (global or per-source).
///
/// The chain holds effect definitions (serializable blueprints) and lazily instantiates
/// runtime Effect objects when apply() is called. Instantiated effects are cached for
/// live and reset when the chain definition changes.
public final class EffectChain: Codable, Equatable {
    /// Stable identity for this chain instance (used for template linking, recent history, etc.)
    public var id: UUID

    /// If this chain originated from a library template, this links back to that template's id.
    public var sourceTemplateId: UUID?

    /// Display name for the chain
    public var name: String?

    /// The effects to apply in sequence (0-n)
    public var effects: [EffectDefinition] {
        didSet {
            // Clear cached instances when definitions change
            _instantiatedEffects = nil
        }
    }

    /// Future: chain-level parameters (e.g., overall strength/mix)
    public var params: [String: AnyCodableValue]?

    // MARK: - Cached Runtime Effects

    /// Cached instantiated effects (lazily created from definitions)
    private var _instantiatedEffects: [Effect]?

    // MARK: - paramsHash

    /// Deterministic hash of chain parameters (for "Recent" dedupe and variant detection).
    /// Excludes identity (`id`, `sourceTemplateId`) and display name (`name`).
    public var paramsHash: String {
        struct PayloadEffect: Codable {
            var type: String
            var params: [String: AnyCodableValue]
        }
        struct Payload: Codable {
            var effects: [PayloadEffect]
            var params: [String: AnyCodableValue]
        }

        let payload = Payload(
            effects: effects.map { def in
                var effectParams = def.params ?? [:]
                if effectParams["_enabled"] == nil {
                    effectParams["_enabled"] = .bool(true)
                }
                return PayloadEffect(type: def.type, params: effectParams)
            },
            params: params ?? [:]
        )

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = (try? encoder.encode(payload)) ?? Data()
        let digest = SHA256.hash(data: data)
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    /// Get or create instantiated effects from definitions
    public var instantiatedEffects: [Effect] {
        if let cached = _instantiatedEffects {
            return cached
        }
        let instances = EffectConfigLoader.instantiateChain(self)
        _instantiatedEffects = instances
        return instances
    }

    /// Create an empty chain
    public init() {
        self.id = UUID()
        self.sourceTemplateId = nil
        self.name = nil
        self.effects = []
        self.params = nil
    }

    /// Create a named chain with effects
    public init(name: String?, effects: [EffectDefinition], params: [String: AnyCodableValue]? = nil) {
        self.id = UUID()
        self.sourceTemplateId = nil
        self.name = name
        self.effects = effects
        self.params = params
    }

    /// Whether this chain has any effects
    public var isEmpty: Bool { effects.isEmpty }

    /// Whether this chain has any enabled effects
    public var hasEnabledEffects: Bool {
        effects.contains { $0.isEnabled }
    }

    /// Maximum lookback required by any effect in this chain.
    /// Used to determine if/how much preroll is needed.
    public var maxRequiredLookback: Int {
        instantiatedEffects.map { $0.requiredLookback }.max() ?? 0
    }

    /// Whether any effect in this chain uses the frame buffer (has temporal dependencies).
    /// Used to determine if preroll is needed before playback.
    public var usesFrameBuffer: Bool {
        maxRequiredLookback > 0
    }

    // MARK: - Apply

    /// Apply all effects in this chain to an image
    /// - Parameters:
    ///   - image: The input image
    ///   - context: The render context (frame index, time, etc.)
    /// - Returns: The processed image after all effects are applied
    public func apply(to image: CIImage, context: inout RenderContext) -> CIImage {
        guard hasEnabledEffects else { return image }

        var result = image
        for effect in instantiatedEffects {
            result = effect.apply(to: result, context: &context)
        }
        return result
    }

    /// Reset all instantiated effects (call when switching compositions)
    public func reset() {
        _instantiatedEffects?.forEach { $0.reset() }
    }

    /// Clear cached effects and force re-instantiation
    public func invalidateCache() {
        _instantiatedEffects = nil
    }

    /// Create a deep copy with fresh effect instances, preserving identity.
    /// Use when you need a separate object instance without changing the chain's UUID.
    public func clone() -> EffectChain {
        let newChain = EffectChain(name: name, effects: effects, params: params)
        newChain.id = id
        newChain.sourceTemplateId = sourceTemplateId
        return newChain
    }

    /// Create a new chain with a new identity, duplicating the definitions.
    /// `sourceTemplateId` must be provided explicitly (often the template's id).
    public convenience init(duplicating chain: EffectChain, sourceTemplateId: UUID?) {
        self.init(name: chain.name, effects: chain.effects, params: chain.params)
        self.sourceTemplateId = sourceTemplateId
    }

    @available(*, deprecated, message: "Use clone() (same id) or init(duplicating:sourceTemplateId:) (new id).")
    /// Create a deep copy with fresh effect instances
    public func copy() -> EffectChain {
        clone()
    }

    // MARK: - Equatable

    public static func == (lhs: EffectChain, rhs: EffectChain) -> Bool {
        lhs.name == rhs.name && lhs.effects == rhs.effects && lhs.params == rhs.params
    }
}

/// Definition of a single effect within a chain.
public struct EffectDefinition: Codable, Equatable {
    /// Optional display name for this effect
    public var name: String?

    /// The effect type (e.g., "DatamoshEffect", "GlitchBlocksEffect")
    public var type: String

    /// Parameters for this effect
    public var params: [String: AnyCodableValue]?

    /// Create an effect with type and optional params
    public init(type: String, params: [String: AnyCodableValue]? = nil) {
        self.name = nil
        self.type = type
        self.params = params
    }

    /// Create an effect with name, type, and optional params
    public init(name: String?, type: String, params: [String: AnyCodableValue]? = nil) {
        self.name = name
        self.type = type
        self.params = params
    }

    /// Whether this effect is enabled (checks _enabled param, defaults to true)
    public var isEnabled: Bool {
        params?["_enabled"]?.boolValue ?? true
    }

    /// Create a copy with updated params
    public func with(params: [String: AnyCodableValue]?) -> EffectDefinition {
        EffectDefinition(name: name, type: type, params: params)
    }
}

// MARK: - Library Config (effects.json)

/// Root configuration for the effects library JSON file
public struct EffectLibraryConfig: Codable {
    public var version: Int
    public var effectChains: [EffectChain]

    public init(version: Int, effectChains: [EffectChain]) {
        self.version = version
        self.effectChains = effectChains
    }
}

// MARK: - Deprecated Aliases (for transition)



// MARK: - EffectChain JSON Compatibility

extension EffectChain {
    /// Coding keys for JSON
    enum CodingKeys: String, CodingKey {
        case id
        case sourceTemplateId
        case name
        case effects
        case params
    }

    public convenience init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)

        let id = try container.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        let sourceTemplateId = try container.decodeIfPresent(UUID.self, forKey: .sourceTemplateId)
        let name = try container.decodeIfPresent(String.self, forKey: .name)
        let params = try container.decodeIfPresent([String: AnyCodableValue].self, forKey: .params)
        let effects = try container.decodeIfPresent([EffectDefinition].self, forKey: .effects) ?? []

        self.init(name: name, effects: effects, params: params)
        self.id = id
        self.sourceTemplateId = sourceTemplateId
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encodeIfPresent(sourceTemplateId, forKey: .sourceTemplateId)
        try container.encodeIfPresent(name, forKey: .name)
        try container.encode(effects, forKey: .effects)
        try container.encodeIfPresent(params, forKey: .params)
    }
}

/// Type-erased codable value to handle mixed parameter types
public enum AnyCodableValue: Codable, Equatable {
    case int(Int)
    case double(Double)
    case bool(Bool)
    case string(String)
    
    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        
        // Try each type in order of specificity
        if let boolValue = try? container.decode(Bool.self) {
            self = .bool(boolValue)
        } else if let intValue = try? container.decode(Int.self) {
            self = .int(intValue)
        } else if let doubleValue = try? container.decode(Double.self) {
            self = .double(doubleValue)
        } else if let stringValue = try? container.decode(String.self) {
            self = .string(stringValue)
        } else {
            throw DecodingError.typeMismatch(
                AnyCodableValue.self,
                DecodingError.Context(
                    codingPath: decoder.codingPath,
                    debugDescription: "Unsupported value type"
                )
            )
        }
    }
    
    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .int(let value): try container.encode(value)
        case .double(let value): try container.encode(value)
        case .bool(let value): try container.encode(value)
        case .string(let value): try container.encode(value)
        }
    }
    
    // Convenience accessors
    public var intValue: Int? {
        switch self {
        case .int(let v): return v
        case .double(let v): return Int(v)
        default: return nil
        }
    }
    
    public var doubleValue: Double? {
        switch self {
        case .double(let v): return v
        case .int(let v): return Double(v)
        default: return nil
        }
    }
    
    public var floatValue: Float? {
        doubleValue.map { Float($0) }
    }
    
    public var boolValue: Bool? {
        if case .bool(let v) = self { return v }
        return nil
    }
    
    public var stringValue: String? {
        if case .string(let v) = self { return v }
        return nil
    }
}
