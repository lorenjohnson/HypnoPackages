//
//  EffectRuntimeDescriptor.swift
//  Hypnograph
//
//  Runtime classification metadata for effects in the pass-chain migration.
//  Lets tooling and UI reason about what is native Metal vs legacy/hybrid stages.
//

import Foundation

/// High-level runtime family for an effect implementation.
public enum EffectRuntimeKind: String, Codable, Equatable {
    /// Unified Metal shader stage (supports optional temporal bindings/state via manifest).
    case metal
    /// Core Image stage (possibly temporal via frameBuffer CIImage access).
    case coreImage
    /// Mixed pipeline (Metal + CI + CPU encode/decode or custom glue).
    case hybrid
    /// CPU/compositor-heavy stage (e.g., text rendering overlays).
    case cpuOverlay
}

/// Runtime metadata for one effect type.
public struct EffectRuntimeDescriptor: Codable, Equatable {
    public var effectType: String
    public var displayName: String
    public var runtimeKind: EffectRuntimeKind
    public var requiredLookback: Int
    public var usesPersistentState: Bool
    public var notes: String?

    public init(
        effectType: String,
        displayName: String,
        runtimeKind: EffectRuntimeKind,
        requiredLookback: Int,
        usesPersistentState: Bool = false,
        notes: String? = nil
    ) {
        self.effectType = effectType
        self.displayName = displayName
        self.runtimeKind = runtimeKind
        self.requiredLookback = requiredLookback
        self.usesPersistentState = usesPersistentState
        self.notes = notes
    }
}

/// Runtime metadata for an instantiated effect chain.
public struct EffectChainRuntimeDescriptor: Codable, Equatable {
    public var chainName: String
    public var stages: [EffectRuntimeDescriptor]

    public init(chainName: String, stages: [EffectRuntimeDescriptor]) {
        self.chainName = chainName
        self.stages = stages
    }

    public var maxRequiredLookback: Int {
        stages.map(\.requiredLookback).max() ?? 0
    }

    public var usesPersistentState: Bool {
        stages.contains(where: \.usesPersistentState)
    }

    public var containsLegacyOrHybridStage: Bool {
        stages.contains { descriptor in
            descriptor.runtimeKind == .coreImage ||
            descriptor.runtimeKind == .hybrid ||
            descriptor.runtimeKind == .cpuOverlay
        }
    }
}
