//
//  PassChainEffect.swift
//  Hypnograph
//
//  Transitional runtime wrapper that treats effects as composable stages.
//  Lets us migrate all chains to a unified pass-chain execution model.
//

import CoreImage

/// Unified pass-chain wrapper for effect execution.
/// Today, stages are existing `Effect` instances; this will expand to native Metal pass stages.
public final class PassChainEffect: Effect {
    public static var parameterSpecs: [String: ParameterSpec] { [:] }

    public var name: String

    /// Ordered stages applied in sequence.
    private var stages: [Effect]
    /// Optional runtime descriptors aligned to stage order.
    private var stageRuntimeDescriptors: [EffectRuntimeDescriptor]

    /// Effect protocol requirement for dynamic construction.
    /// Pass chains are assembled by loader/registry, not created directly from params.
    public required init?(params: [String: AnyCodableValue]?) {
        return nil
    }

    public init(name: String, stages: [Effect], stageRuntimeDescriptors: [EffectRuntimeDescriptor] = []) {
        self.name = name
        self.stages = stages
        self.stageRuntimeDescriptors = stageRuntimeDescriptors
    }

    /// Maximum lookback required by any stage in this chain.
    public var requiredLookback: Int {
        stages.map(\.requiredLookback).max() ?? 0
    }

    public func apply(to image: CIImage, context: inout RenderContext) -> CIImage {
        var result = image
        for stage in stages {
            result = stage.apply(to: result, context: &context)
        }
        return result
    }

    public func reset() {
        stages.forEach { $0.reset() }
    }

    public func copy() -> Effect {
        PassChainEffect(
            name: name,
            stages: stages.map { $0.copy() },
            stageRuntimeDescriptors: stageRuntimeDescriptors
        )
    }

    /// Flatten nested pass chains into a single stage list.
    public static func flatten(name: String, effects: [Effect]) -> PassChainEffect {
        var flattened: [Effect] = []
        var flattenedDescriptors: [EffectRuntimeDescriptor] = []
        for effect in effects {
            if let passChain = effect as? PassChainEffect {
                flattened.append(contentsOf: passChain.stagesSnapshot())
                flattenedDescriptors.append(contentsOf: passChain.stageRuntimeDescriptorsSnapshot())
            } else {
                flattened.append(effect)
            }
        }
        return PassChainEffect(name: name, stages: flattened, stageRuntimeDescriptors: flattenedDescriptors)
    }

    /// Internal snapshot of raw stages, used to flatten nested wrappers during migration.
    internal func stagesSnapshot() -> [Effect] {
        stages
    }

    /// Runtime descriptors aligned to internal stages, when available.
    public func runtimeDescriptors() -> [EffectRuntimeDescriptor] {
        stageRuntimeDescriptors
    }

    /// Snapshot for flattening nested pass-chain wrappers during migration.
    internal func stageRuntimeDescriptorsSnapshot() -> [EffectRuntimeDescriptor] {
        stageRuntimeDescriptors
    }
}
