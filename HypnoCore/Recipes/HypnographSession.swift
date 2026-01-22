//
//  HypnographSession.swift
//  Hypnograph
//
//  "Blueprint" for a render: pure data, no renderer knowledge.
//  This is the single source of truth for a hypnogram composition and (eventually) a multi-clip tape.
//

import Foundation
import CoreMedia

// MARK: - Hypnogram

/// A single clip: layered sources, effects, duration, and playback rate.
public struct Hypnogram: Codable {
    /// Stable identity for this clip (for UI/state and future history operations).
    public var id: UUID
    public var layers: [HypnogramLayer]
    public var targetDuration: CMTime

    /// Playback rate (1.0 = normal speed, 0.5 = half speed, 2.0 = double speed)
    public var playRate: Float

    /// The global effect chain for this clip.
    public var effectChain: EffectChain

    /// When this clip was created
    public var createdAt: Date

    private enum CodingKeys: String, CodingKey {
        case id, layers, targetDuration, playRate, effectChain, createdAt

        // Legacy keys (Phase 1–3 schema)
        case sources
    }

    public init(
        id: UUID = UUID(),
        layers: [HypnogramLayer],
        targetDuration: CMTime,
        playRate: Float = 1.0,
        effectChain: EffectChain? = nil,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.layers = layers
        self.targetDuration = targetDuration
        self.playRate = playRate
        self.effectChain = effectChain ?? EffectChain()
        self.createdAt = createdAt
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        if let decodedLayers = try container.decodeIfPresent([HypnogramLayer].self, forKey: .layers) {
            layers = decodedLayers
        } else {
            // Temporary migration support (Phase 4, Option A):
            // Prior schema stored Hypnogram layers under the `sources` key.
            layers = try container.decode([HypnogramLayer].self, forKey: .sources)
        }
        targetDuration = try container.decode(CodableCMTime.self, forKey: .targetDuration).cmTime
        playRate = try container.decodeIfPresent(Float.self, forKey: .playRate) ?? 1.0
        effectChain = try container.decodeIfPresent(EffectChain.self, forKey: .effectChain) ?? EffectChain()
        createdAt = try container.decodeIfPresent(Date.self, forKey: .createdAt) ?? Date()
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(layers, forKey: .layers)
        try container.encode(CodableCMTime(targetDuration), forKey: .targetDuration)
        try container.encode(playRate, forKey: .playRate)
        try container.encode(effectChain, forKey: .effectChain)
        try container.encode(createdAt, forKey: .createdAt)
    }

    /// Create a deep copy with fresh effect instances for export.
    /// This prevents export from sharing mutable state with preview.
    public func copyForExport() -> Hypnogram {
        // Copy per-source effect chains
        let copiedLayers = layers.map { layer in
            var copy = layer
            copy.effectChain = layer.effectChain.clone()
            return copy
        }

        return Hypnogram(
            id: id,
            layers: copiedLayers,
            targetDuration: targetDuration,
            playRate: playRate,
            effectChain: effectChain.clone(),
            createdAt: createdAt
        )
    }

    public mutating func ensureEffectChainNames() {
        if !effectChain.effects.isEmpty &&
            (effectChain.name == nil || effectChain.name?.isEmpty == true) {
            effectChain.name = "Global (imported)"
        }

        for index in layers.indices {
            let chain = layers[index].effectChain
            if !chain.effects.isEmpty &&
                (chain.name == nil || chain.name?.isEmpty == true) {
                layers[index].effectChain.name = "Source \(index + 1) (imported)"
            }
        }
    }
}

/// Session/container of playable items (hypnograms).
public struct HypnographSession: Codable {
    public var hypnograms: [Hypnogram]

    /// Base64-encoded JPEG snapshot for thumbnails (1080p-ish).
    public var snapshot: String?

    /// When this session was created
    public var createdAt: Date

    private enum CodingKeys: String, CodingKey {
        case hypnograms, snapshot, createdAt

        // Legacy keys (Phase 1–3 schema)
        case clips

        // Legacy single-clip keys (pre-multi-clip)
        case sources, targetDuration, playRate, effectChain
    }

    public init(
        hypnograms: [Hypnogram],
        snapshot: String? = nil,
        createdAt: Date = Date()
    ) {
        self.hypnograms = hypnograms
        self.snapshot = snapshot
        self.createdAt = createdAt
    }

    /// Convenience initializer for a single-hypnogram session.
    public init(
        layers: [HypnogramLayer],
        targetDuration: CMTime,
        playRate: Float = 1.0,
        effectChain: EffectChain? = nil,
        snapshot: String? = nil,
        createdAt: Date = Date()
    ) {
        self.init(
            hypnograms: [
                Hypnogram(
                    layers: layers,
                    targetDuration: targetDuration,
                    playRate: playRate,
                    effectChain: effectChain,
                    createdAt: createdAt
                )
            ],
            snapshot: snapshot,
            createdAt: createdAt
        )
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)

        // New canonical format: `hypnograms: [...]`
        if let decoded = try container.decodeIfPresent([Hypnogram].self, forKey: .hypnograms) {
            hypnograms = decoded
            snapshot = try container.decodeIfPresent(String.self, forKey: .snapshot)
            createdAt = try container.decodeIfPresent(Date.self, forKey: .createdAt) ?? Date()
            return
        }

        // Legacy format (Phase 1–3): `clips: [...]`
        if let decoded = try container.decodeIfPresent([Hypnogram].self, forKey: .clips) {
            hypnograms = decoded
            snapshot = try container.decodeIfPresent(String.self, forKey: .snapshot)
            createdAt = try container.decodeIfPresent(Date.self, forKey: .createdAt) ?? Date()
            return
        }

        // Legacy format: single-hypnogram at top-level
        let sources = try container.decode([HypnogramLayer].self, forKey: .sources)
        let targetDuration = try container.decode(CodableCMTime.self, forKey: .targetDuration).cmTime
        let playRate = try container.decodeIfPresent(Float.self, forKey: .playRate) ?? 1.0
        let effectChain = try container.decodeIfPresent(EffectChain.self, forKey: .effectChain) ?? EffectChain()
        snapshot = try container.decodeIfPresent(String.self, forKey: .snapshot)
        createdAt = try container.decodeIfPresent(Date.self, forKey: .createdAt) ?? Date()

        hypnograms = [
            Hypnogram(
                layers: sources,
                targetDuration: targetDuration,
                playRate: playRate,
                effectChain: effectChain,
                createdAt: createdAt
            )
        ]
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(hypnograms, forKey: .hypnograms)
        try container.encodeIfPresent(snapshot, forKey: .snapshot)
        try container.encode(createdAt, forKey: .createdAt)
    }

    /// Create a deep copy with fresh effect instances for export.
    /// This prevents export from sharing mutable state with preview.
    public func copyForExport() -> HypnographSession {
        return HypnographSession(
            hypnograms: hypnograms.map { $0.copyForExport() },
            snapshot: snapshot,
            createdAt: createdAt
        )
    }

    public mutating func ensureEffectChainNames() {
        for index in hypnograms.indices {
            hypnograms[index].ensureEffectChainNames()
        }
    }
}
