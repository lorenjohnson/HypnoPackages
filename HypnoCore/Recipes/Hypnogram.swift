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

    /// Optional selected composition index for multi-composition documents.
    public var currentCompositionIndex: Int?

    /// Last-used display and playback context for this working document.
    public var lastAspectRatio: AspectRatio?
    public var lastPlayerResolution: OutputResolution?
    public var lastOutputResolution: OutputResolution?
    public var lastSourceFraming: SourceFraming?
    public var lastTransitionStyle: TransitionRenderer.TransitionType?
    public var lastTransitionDuration: Double?

    /// Optional document-level poster image.
    public var snapshot: String?

    /// Lightweight preview image for lists. Falls back to the first composition snapshot if needed.
    public var thumbnail: String? {
        compositions.first?.thumbnail
        ?? compositions.first?.snapshot
        ?? snapshot
    }

    /// When this hypnogram was created.
    public var createdAt: Date

    private enum CodingKeys: String, CodingKey {
        case compositions
        case legacyHypnograms = "hypnograms"
        case snapshot, createdAt, currentCompositionIndex
        case lastAspectRatio, lastPlayerResolution, lastOutputResolution, lastSourceFraming
        case lastTransitionStyle, lastTransitionDuration

        // Legacy keys (Phase 1-3 schema)
        case clips

        // Legacy single-composition keys (pre-multi-clip)
        case sources, targetDuration, playRate, effectChain
    }

    public init(
        compositions: [Composition],
        currentCompositionIndex: Int? = nil,
        lastAspectRatio: AspectRatio? = nil,
        lastPlayerResolution: OutputResolution? = nil,
        lastOutputResolution: OutputResolution? = nil,
        lastSourceFraming: SourceFraming? = nil,
        lastTransitionStyle: TransitionRenderer.TransitionType? = nil,
        lastTransitionDuration: Double? = nil,
        snapshot: String? = nil,
        createdAt: Date = Date()
    ) {
        self.compositions = compositions
        self.currentCompositionIndex = currentCompositionIndex
        self.lastAspectRatio = lastAspectRatio
        self.lastPlayerResolution = lastPlayerResolution
        self.lastOutputResolution = lastOutputResolution
        self.lastSourceFraming = lastSourceFraming
        self.lastTransitionStyle = lastTransitionStyle
        self.lastTransitionDuration = lastTransitionDuration
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
            currentCompositionIndex: 0,
            lastAspectRatio: nil,
            lastPlayerResolution: nil,
            lastOutputResolution: nil,
            lastSourceFraming: nil,
            lastTransitionStyle: nil,
            lastTransitionDuration: nil,
            snapshot: snapshot,
            createdAt: createdAt
        )
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)

        // Canonical format: `compositions: [...]`
        if let decoded = try container.decodeIfPresent([Composition].self, forKey: .compositions) {
            compositions = decoded
            currentCompositionIndex = try container.decodeIfPresent(Int.self, forKey: .currentCompositionIndex)
            lastAspectRatio = try container.decodeIfPresent(AspectRatio.self, forKey: .lastAspectRatio)
            lastPlayerResolution = try container.decodeIfPresent(OutputResolution.self, forKey: .lastPlayerResolution)
            lastOutputResolution = try container.decodeIfPresent(OutputResolution.self, forKey: .lastOutputResolution)
            lastSourceFraming = try container.decodeIfPresent(SourceFraming.self, forKey: .lastSourceFraming)
            lastTransitionStyle = try container.decodeIfPresent(TransitionRenderer.TransitionType.self, forKey: .lastTransitionStyle)
            lastTransitionDuration = try container.decodeIfPresent(Double.self, forKey: .lastTransitionDuration)
            snapshot = try container.decodeIfPresent(String.self, forKey: .snapshot)
            createdAt = try container.decodeIfPresent(Date.self, forKey: .createdAt) ?? Date()
            return
        }

        // Prior renamed format: `hypnograms: [...]`
        if let decoded = try container.decodeIfPresent([Composition].self, forKey: .legacyHypnograms) {
            compositions = decoded
            currentCompositionIndex = try container.decodeIfPresent(Int.self, forKey: .currentCompositionIndex)
            lastAspectRatio = try container.decodeIfPresent(AspectRatio.self, forKey: .lastAspectRatio)
            lastPlayerResolution = try container.decodeIfPresent(OutputResolution.self, forKey: .lastPlayerResolution)
            lastOutputResolution = try container.decodeIfPresent(OutputResolution.self, forKey: .lastOutputResolution)
            lastSourceFraming = try container.decodeIfPresent(SourceFraming.self, forKey: .lastSourceFraming)
            lastTransitionStyle = try container.decodeIfPresent(TransitionRenderer.TransitionType.self, forKey: .lastTransitionStyle)
            lastTransitionDuration = try container.decodeIfPresent(Double.self, forKey: .lastTransitionDuration)
            snapshot = try container.decodeIfPresent(String.self, forKey: .snapshot)
            createdAt = try container.decodeIfPresent(Date.self, forKey: .createdAt) ?? Date()
            return
        }

        // Legacy format (Phase 1-3): `clips: [...]`
        if let decoded = try container.decodeIfPresent([Composition].self, forKey: .clips) {
            compositions = decoded
            currentCompositionIndex = try container.decodeIfPresent(Int.self, forKey: .currentCompositionIndex)
            lastAspectRatio = try container.decodeIfPresent(AspectRatio.self, forKey: .lastAspectRatio)
            lastPlayerResolution = try container.decodeIfPresent(OutputResolution.self, forKey: .lastPlayerResolution)
            lastOutputResolution = try container.decodeIfPresent(OutputResolution.self, forKey: .lastOutputResolution)
            lastSourceFraming = try container.decodeIfPresent(SourceFraming.self, forKey: .lastSourceFraming)
            lastTransitionStyle = try container.decodeIfPresent(TransitionRenderer.TransitionType.self, forKey: .lastTransitionStyle)
            lastTransitionDuration = try container.decodeIfPresent(Double.self, forKey: .lastTransitionDuration)
            snapshot = try container.decodeIfPresent(String.self, forKey: .snapshot)
            createdAt = try container.decodeIfPresent(Date.self, forKey: .createdAt) ?? Date()
            return
        }

        // Legacy format: single composition at top level.
        let layers = try container.decode([Layer].self, forKey: .sources)
        let targetDuration = try container.decode(CodableCMTime.self, forKey: .targetDuration).cmTime
        let playRate = try container.decodeIfPresent(Float.self, forKey: .playRate) ?? 1.0
        let effectChain = try container.decodeIfPresent(EffectChain.self, forKey: .effectChain) ?? EffectChain()
        lastAspectRatio = try container.decodeIfPresent(AspectRatio.self, forKey: .lastAspectRatio)
        lastPlayerResolution = try container.decodeIfPresent(OutputResolution.self, forKey: .lastPlayerResolution)
        lastOutputResolution = try container.decodeIfPresent(OutputResolution.self, forKey: .lastOutputResolution)
        lastSourceFraming = try container.decodeIfPresent(SourceFraming.self, forKey: .lastSourceFraming)
        lastTransitionStyle = try container.decodeIfPresent(TransitionRenderer.TransitionType.self, forKey: .lastTransitionStyle)
        lastTransitionDuration = try container.decodeIfPresent(Double.self, forKey: .lastTransitionDuration)
        snapshot = try container.decodeIfPresent(String.self, forKey: .snapshot)
        createdAt = try container.decodeIfPresent(Date.self, forKey: .createdAt) ?? Date()
        currentCompositionIndex = 0

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
        try container.encodeIfPresent(currentCompositionIndex, forKey: .currentCompositionIndex)
        try container.encodeIfPresent(lastAspectRatio, forKey: .lastAspectRatio)
        try container.encodeIfPresent(lastPlayerResolution, forKey: .lastPlayerResolution)
        try container.encodeIfPresent(lastOutputResolution, forKey: .lastOutputResolution)
        try container.encodeIfPresent(lastSourceFraming, forKey: .lastSourceFraming)
        try container.encodeIfPresent(lastTransitionStyle, forKey: .lastTransitionStyle)
        try container.encodeIfPresent(lastTransitionDuration, forKey: .lastTransitionDuration)
        try container.encodeIfPresent(snapshot, forKey: .snapshot)
        try container.encode(createdAt, forKey: .createdAt)
    }

    /// Create a deep copy with fresh effect instances for export.
    /// This prevents export from sharing mutable state with preview.
    public func copyForExport() -> Hypnogram {
        Hypnogram(
            compositions: compositions.map { $0.copyForExport() },
            currentCompositionIndex: currentCompositionIndex,
            lastAspectRatio: lastAspectRatio,
            lastPlayerResolution: lastPlayerResolution,
            lastOutputResolution: lastOutputResolution,
            lastSourceFraming: lastSourceFraming,
            lastTransitionStyle: lastTransitionStyle,
            lastTransitionDuration: lastTransitionDuration,
            snapshot: snapshot,
            createdAt: createdAt
        )
    }

    public mutating func ensureEffectChainNames() {
        for index in compositions.indices {
            compositions[index].ensureEffectChainNames()
        }
    }
}
