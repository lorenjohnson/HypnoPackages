//
//  Hypnogram.swift
//  Hypnograph
//
//  Blueprint for a saved hypnogram document: pure data, no renderer knowledge.
//

import Foundation
import CoreMedia

// MARK: - Hypnogram

/// Top-level saved container of playable compositions.
public struct Hypnogram: Codable {
    public var compositions: [Composition]

    /// Base64-encoded JPEG snapshot for thumbnails (1080p-ish).
    public var snapshot: String?

    /// When this hypnogram was created.
    public var createdAt: Date

    private enum CodingKeys: String, CodingKey {
        case compositions
        case legacyHypnograms = "hypnograms"
        case snapshot, createdAt

        // Legacy keys (Phase 1-3 schema)
        case clips

        // Legacy single-composition keys (pre-multi-clip)
        case sources, targetDuration, playRate, effectChain
    }

    public init(
        compositions: [Composition],
        snapshot: String? = nil,
        createdAt: Date = Date()
    ) {
        self.compositions = compositions
        self.snapshot = snapshot
        self.createdAt = createdAt
    }

    /// Convenience initializer for a single-composition hypnogram.
    public init(
        layers: [Layer],
        targetDuration: CMTime,
        playRate: Float = 1.0,
        effectChain: EffectChain? = nil,
        snapshot: String? = nil,
        createdAt: Date = Date()
    ) {
        self.init(
            compositions: [
                Composition(
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

    @available(*, deprecated, renamed: "init(compositions:snapshot:createdAt:)")
    public init(
        hypnograms: [Composition],
        snapshot: String? = nil,
        createdAt: Date = Date()
    ) {
        self.init(compositions: hypnograms, snapshot: snapshot, createdAt: createdAt)
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)

        // Canonical format: `compositions: [...]`
        if let decoded = try container.decodeIfPresent([Composition].self, forKey: .compositions) {
            compositions = decoded
            snapshot = try container.decodeIfPresent(String.self, forKey: .snapshot)
            createdAt = try container.decodeIfPresent(Date.self, forKey: .createdAt) ?? Date()
            return
        }

        // Prior renamed format: `hypnograms: [...]`
        if let decoded = try container.decodeIfPresent([Composition].self, forKey: .legacyHypnograms) {
            compositions = decoded
            snapshot = try container.decodeIfPresent(String.self, forKey: .snapshot)
            createdAt = try container.decodeIfPresent(Date.self, forKey: .createdAt) ?? Date()
            return
        }

        // Legacy format (Phase 1-3): `clips: [...]`
        if let decoded = try container.decodeIfPresent([Composition].self, forKey: .clips) {
            compositions = decoded
            snapshot = try container.decodeIfPresent(String.self, forKey: .snapshot)
            createdAt = try container.decodeIfPresent(Date.self, forKey: .createdAt) ?? Date()
            return
        }

        // Legacy format: single composition at top level.
        let layers = try container.decode([Layer].self, forKey: .sources)
        let targetDuration = try container.decode(CodableCMTime.self, forKey: .targetDuration).cmTime
        let playRate = try container.decodeIfPresent(Float.self, forKey: .playRate) ?? 1.0
        let effectChain = try container.decodeIfPresent(EffectChain.self, forKey: .effectChain) ?? EffectChain()
        snapshot = try container.decodeIfPresent(String.self, forKey: .snapshot)
        createdAt = try container.decodeIfPresent(Date.self, forKey: .createdAt) ?? Date()

        compositions = [
            Composition(
                layers: layers,
                targetDuration: targetDuration,
                playRate: playRate,
                effectChain: effectChain,
                createdAt: createdAt
            )
        ]
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(compositions, forKey: .compositions)
        try container.encodeIfPresent(snapshot, forKey: .snapshot)
        try container.encode(createdAt, forKey: .createdAt)
    }

    /// Create a deep copy with fresh effect instances for export.
    /// This prevents export from sharing mutable state with preview.
    public func copyForExport() -> Hypnogram {
        Hypnogram(
            compositions: compositions.map { $0.copyForExport() },
            snapshot: snapshot,
            createdAt: createdAt
        )
    }

    public mutating func ensureEffectChainNames() {
        for index in compositions.indices {
            compositions[index].ensureEffectChainNames()
        }
    }

    @available(*, deprecated, renamed: "compositions")
    public var hypnograms: [Composition] {
        get { compositions }
        set { compositions = newValue }
    }
}

@available(*, deprecated, renamed: "Hypnogram")
public typealias HypnographSession = Hypnogram
