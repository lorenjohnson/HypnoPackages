//
//  Composition.swift
//  Hypnograph
//
//  Blueprint for one playable unit inside a saved hypnogram.
//

import Foundation
import CoreMedia

// MARK: - Composition

/// One playable unit: layered media, effects, duration, and playback rate.
public struct Composition: Codable {
    /// Stable identity for this composition (for UI/state and future history operations).
    public var id: UUID
    public var layers: [Layer]
    public var targetDuration: CMTime

    /// Playback rate (1.0 = normal speed, 0.5 = half speed, 2.0 = double speed).
    public var playRate: Float

    /// The effect chain for this composition.
    public var effectChain: EffectChain

    /// Optional larger preview image for this composition (typically a JPEG base64 snapshot).
    public var snapshot: String?

    /// Optional lightweight preview image for list and timeline display.
    public var thumbnail: String?

    /// When this composition was created.
    public var createdAt: Date

    private enum CodingKeys: String, CodingKey {
        case id, layers, targetDuration, playRate, effectChain, snapshot, thumbnail, createdAt

        // Legacy keys (Phase 1-3 schema)
        case sources
    }

    public init(
        id: UUID = UUID(),
        layers: [Layer],
        targetDuration: CMTime,
        playRate: Float = 1.0,
        effectChain: EffectChain? = nil,
        snapshot: String? = nil,
        thumbnail: String? = nil,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.layers = layers
        self.targetDuration = targetDuration
        self.playRate = playRate
        self.effectChain = effectChain ?? EffectChain()
        self.snapshot = snapshot
        self.thumbnail = thumbnail
        self.createdAt = createdAt
    }

    public static func effectiveDuration(for layers: [Layer], fallback: CMTime) -> CMTime {
        guard let longestLayerSeconds = layers.map(\.mediaClip.duration.seconds).max() else {
            return fallback
        }

        let clampedSeconds = max(0.1, longestLayerSeconds)
        return CMTime(seconds: clampedSeconds, preferredTimescale: 600)
    }

    public var effectiveDuration: CMTime {
        Self.effectiveDuration(for: layers, fallback: targetDuration)
    }

    public mutating func syncTargetDurationToLayers() {
        guard !layers.isEmpty else { return }
        targetDuration = effectiveDuration
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        if let decodedLayers = try container.decodeIfPresent([Layer].self, forKey: .layers) {
            layers = decodedLayers
        } else {
            // Legacy schema stored composition layers under the `sources` key.
            layers = try container.decode([Layer].self, forKey: .sources)
        }
        targetDuration = try container.decode(CodableCMTime.self, forKey: .targetDuration).cmTime
        playRate = try container.decodeIfPresent(Float.self, forKey: .playRate) ?? 1.0
        effectChain = try container.decodeIfPresent(EffectChain.self, forKey: .effectChain) ?? EffectChain()
        snapshot = try container.decodeIfPresent(String.self, forKey: .snapshot)
        thumbnail = try container.decodeIfPresent(String.self, forKey: .thumbnail)
        createdAt = try container.decodeIfPresent(Date.self, forKey: .createdAt) ?? Date()
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(layers, forKey: .layers)
        try container.encode(CodableCMTime(targetDuration), forKey: .targetDuration)
        try container.encode(playRate, forKey: .playRate)
        try container.encode(effectChain, forKey: .effectChain)
        try container.encodeIfPresent(snapshot, forKey: .snapshot)
        try container.encodeIfPresent(thumbnail, forKey: .thumbnail)
        try container.encode(createdAt, forKey: .createdAt)
    }

    /// Create a deep copy with fresh effect instances for export.
    /// This prevents export from sharing mutable state with preview.
    public func copyForExport() -> Composition {
        let copiedLayers = layers.map { layer in
            var copy = layer
            copy.effectChain = layer.effectChain.clone()
            return copy
        }

        return Composition(
            id: id,
            layers: copiedLayers,
            targetDuration: effectiveDuration,
            playRate: playRate,
            effectChain: effectChain.clone(),
            snapshot: snapshot,
            thumbnail: thumbnail,
            createdAt: createdAt
        )
    }

    public mutating func ensureEffectChainNames() {
        if !effectChain.effects.isEmpty &&
            (effectChain.name == nil || effectChain.name?.isEmpty == true) {
            effectChain.name = "Composition (imported)"
        }

        for index in layers.indices {
            let chain = layers[index].effectChain
            if !chain.effects.isEmpty &&
                (chain.name == nil || chain.name?.isEmpty == true) {
                layers[index].effectChain.name = "Layer \(index + 1) (imported)"
            }
        }
    }
}
