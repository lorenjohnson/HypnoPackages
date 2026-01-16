//
//  HypnogramRecipe.swift
//  Hypnograph
//
//  "Blueprint" for a render: pure data, no renderer knowledge.
//  This is the single source of truth for a hypnogram composition and (eventually) a multi-clip tape.
//

import Foundation
import CoreMedia

// MARK: - Hypnogram clip

/// A single clip: layered sources, effects, duration, and playback rate.
public struct HypnogramClip: Codable {
    /// Stable identity for this clip (for UI/state and future history operations).
    public var id: UUID
    public var sources: [HypnogramSource]
    public var targetDuration: CMTime

    /// Playback rate (1.0 = normal speed, 0.5 = half speed, 2.0 = double speed)
    public var playRate: Float

    /// The global effect chain for this clip.
    public var effectChain: EffectChain

    /// When this clip was created
    public var createdAt: Date

    private enum CodingKeys: String, CodingKey {
        case id, sources, targetDuration, playRate, effectChain, createdAt
    }

    public init(
        id: UUID = UUID(),
        sources: [HypnogramSource],
        targetDuration: CMTime,
        playRate: Float = 1.0,
        effectChain: EffectChain? = nil,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.sources = sources
        self.targetDuration = targetDuration
        self.playRate = playRate
        self.effectChain = effectChain ?? EffectChain()
        self.createdAt = createdAt
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        sources = try container.decode([HypnogramSource].self, forKey: .sources)
        targetDuration = try container.decode(CodableCMTime.self, forKey: .targetDuration).cmTime
        playRate = try container.decodeIfPresent(Float.self, forKey: .playRate) ?? 1.0
        effectChain = try container.decodeIfPresent(EffectChain.self, forKey: .effectChain) ?? EffectChain()
        createdAt = try container.decodeIfPresent(Date.self, forKey: .createdAt) ?? Date()
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(sources, forKey: .sources)
        try container.encode(CodableCMTime(targetDuration), forKey: .targetDuration)
        try container.encode(playRate, forKey: .playRate)
        try container.encode(effectChain, forKey: .effectChain)
        try container.encode(createdAt, forKey: .createdAt)
    }

    /// Create a deep copy with fresh effect instances for export.
    /// This prevents export from sharing mutable state with preview.
    public func copyForExport() -> HypnogramClip {
        // Copy per-source effect chains
        let copiedSources = sources.map { source in
            var copy = source
            copy.effectChain = source.effectChain.clone()
            return copy
        }

        return HypnogramClip(
            id: id,
            sources: copiedSources,
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

        for index in sources.indices {
            let chain = sources[index].effectChain
            if !chain.effects.isEmpty &&
                (chain.name == nil || chain.name?.isEmpty == true) {
                sources[index].effectChain.name = "Source \(index + 1) (imported)"
            }
        }
    }
}

/// A complete "hypnogram" recipe: ordered sources, effects, and target render duration.
/// This is the single source of truth for everything about a hypnogram composition.
public struct HypnogramRecipe: Codable {
    /// Materialized clips. A single-clip hypnogram is represented by `clips.count == 1`.
    public var clips: [HypnogramClip]

    /// Base64-encoded JPEG snapshot for thumbnails (1080p-ish).
    public var snapshot: String?

    /// When this recipe was created
    public var createdAt: Date

    private enum CodingKeys: String, CodingKey {
        case clips, snapshot, createdAt

        // Legacy single-clip keys (pre-multi-clip)
        case sources, targetDuration, playRate, effectChain
    }

    public init(
        clips: [HypnogramClip],
        snapshot: String? = nil,
        createdAt: Date = Date()
    ) {
        self.clips = clips
        self.snapshot = snapshot
        self.createdAt = createdAt
    }

    /// Convenience initializer for a single-clip recipe (legacy mental model).
    public init(
        sources: [HypnogramSource],
        targetDuration: CMTime,
        playRate: Float = 1.0,
        effectChain: EffectChain? = nil,
        snapshot: String? = nil,
        createdAt: Date = Date()
    ) {
        self.init(
            clips: [
                HypnogramClip(
                    sources: sources,
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

        // New canonical format: `clips: [...]`
        if let decodedClips = try container.decodeIfPresent([HypnogramClip].self, forKey: .clips) {
            clips = decodedClips
            snapshot = try container.decodeIfPresent(String.self, forKey: .snapshot)
            createdAt = try container.decodeIfPresent(Date.self, forKey: .createdAt) ?? Date()
            return
        }

        // Legacy format: single-clip at top-level
        let sources = try container.decode([HypnogramSource].self, forKey: .sources)
        let targetDuration = try container.decode(CodableCMTime.self, forKey: .targetDuration).cmTime
        let playRate = try container.decodeIfPresent(Float.self, forKey: .playRate) ?? 1.0
        let effectChain = try container.decodeIfPresent(EffectChain.self, forKey: .effectChain) ?? EffectChain()
        snapshot = try container.decodeIfPresent(String.self, forKey: .snapshot)
        createdAt = try container.decodeIfPresent(Date.self, forKey: .createdAt) ?? Date()

        clips = [
            HypnogramClip(
                sources: sources,
                targetDuration: targetDuration,
                playRate: playRate,
                effectChain: effectChain,
                createdAt: createdAt
            )
        ]
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(clips, forKey: .clips)
        try container.encodeIfPresent(snapshot, forKey: .snapshot)
        try container.encode(createdAt, forKey: .createdAt)
    }

    /// Create a deep copy with fresh effect instances for export.
    /// This prevents export from sharing mutable state with preview.
    public func copyForExport() -> HypnogramRecipe {
        return HypnogramRecipe(
            clips: clips.map { $0.copyForExport() },
            snapshot: snapshot,
            createdAt: createdAt
        )
    }

    public mutating func ensureEffectChainNames() {
        for index in clips.indices {
            clips[index].ensureEffectChainNames()
        }
    }
}
