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

    /// Optional display and playback context for this working document.
    public var aspectRatio: AspectRatio?
    public var outputResolution: OutputResolution?
    public var sourceFraming: SourceFraming?
    public var transitionStyle: TransitionRenderer.TransitionType?
    public var transitionDuration: Double?

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
        case aspectRatio, outputResolution, sourceFraming
        case transitionStyle, transitionDuration

        // Legacy keys (Phase 1-3 schema)
        case clips

        // Legacy single-composition keys (pre-multi-clip)
        case sources, targetDuration, playRate, effectChain
    }

    public init(
        compositions: [Composition],
        currentCompositionIndex: Int? = nil,
        aspectRatio: AspectRatio? = nil,
        outputResolution: OutputResolution? = nil,
        sourceFraming: SourceFraming? = nil,
        transitionStyle: TransitionRenderer.TransitionType? = nil,
        transitionDuration: Double? = nil,
        snapshot: String? = nil,
        createdAt: Date = Date()
    ) {
        self.compositions = compositions
        self.currentCompositionIndex = currentCompositionIndex
        self.aspectRatio = aspectRatio
        self.outputResolution = outputResolution
        self.sourceFraming = sourceFraming
        self.transitionStyle = transitionStyle
        self.transitionDuration = transitionDuration
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
            aspectRatio: nil,
            outputResolution: nil,
            sourceFraming: nil,
            transitionStyle: nil,
            transitionDuration: nil,
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
            aspectRatio = try container.decodeIfPresent(AspectRatio.self, forKey: .aspectRatio)
            outputResolution = try container.decodeIfPresent(OutputResolution.self, forKey: .outputResolution)
            sourceFraming = try container.decodeIfPresent(SourceFraming.self, forKey: .sourceFraming)
            transitionStyle = try container.decodeIfPresent(TransitionRenderer.TransitionType.self, forKey: .transitionStyle)
            transitionDuration = try container.decodeIfPresent(Double.self, forKey: .transitionDuration)
            snapshot = try container.decodeIfPresent(String.self, forKey: .snapshot)
            createdAt = try container.decodeIfPresent(Date.self, forKey: .createdAt) ?? Date()
            return
        }

        // Prior renamed format: `hypnograms: [...]`
        if let decoded = try container.decodeIfPresent([Composition].self, forKey: .legacyHypnograms) {
            compositions = decoded
            currentCompositionIndex = try container.decodeIfPresent(Int.self, forKey: .currentCompositionIndex)
            aspectRatio = try container.decodeIfPresent(AspectRatio.self, forKey: .aspectRatio)
            outputResolution = try container.decodeIfPresent(OutputResolution.self, forKey: .outputResolution)
            sourceFraming = try container.decodeIfPresent(SourceFraming.self, forKey: .sourceFraming)
            transitionStyle = try container.decodeIfPresent(TransitionRenderer.TransitionType.self, forKey: .transitionStyle)
            transitionDuration = try container.decodeIfPresent(Double.self, forKey: .transitionDuration)
            snapshot = try container.decodeIfPresent(String.self, forKey: .snapshot)
            createdAt = try container.decodeIfPresent(Date.self, forKey: .createdAt) ?? Date()
            return
        }

        // Legacy format (Phase 1-3): `clips: [...]`
        if let decoded = try container.decodeIfPresent([Composition].self, forKey: .clips) {
            compositions = decoded
            currentCompositionIndex = try container.decodeIfPresent(Int.self, forKey: .currentCompositionIndex)
            aspectRatio = try container.decodeIfPresent(AspectRatio.self, forKey: .aspectRatio)
            outputResolution = try container.decodeIfPresent(OutputResolution.self, forKey: .outputResolution)
            sourceFraming = try container.decodeIfPresent(SourceFraming.self, forKey: .sourceFraming)
            transitionStyle = try container.decodeIfPresent(TransitionRenderer.TransitionType.self, forKey: .transitionStyle)
            transitionDuration = try container.decodeIfPresent(Double.self, forKey: .transitionDuration)
            snapshot = try container.decodeIfPresent(String.self, forKey: .snapshot)
            createdAt = try container.decodeIfPresent(Date.self, forKey: .createdAt) ?? Date()
            return
        }

        // Legacy format: single composition at top level.
        let layers = try container.decode([Layer].self, forKey: .sources)
        let targetDuration = try container.decode(CodableCMTime.self, forKey: .targetDuration).cmTime
        let playRate = try container.decodeIfPresent(Float.self, forKey: .playRate) ?? 1.0
        let effectChain = try container.decodeIfPresent(EffectChain.self, forKey: .effectChain) ?? EffectChain()
        aspectRatio = try container.decodeIfPresent(AspectRatio.self, forKey: .aspectRatio)
        outputResolution = try container.decodeIfPresent(OutputResolution.self, forKey: .outputResolution)
        sourceFraming = try container.decodeIfPresent(SourceFraming.self, forKey: .sourceFraming)
        transitionStyle = try container.decodeIfPresent(TransitionRenderer.TransitionType.self, forKey: .transitionStyle)
        transitionDuration = try container.decodeIfPresent(Double.self, forKey: .transitionDuration)
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
        try container.encodeIfPresent(aspectRatio, forKey: .aspectRatio)
        try container.encodeIfPresent(outputResolution, forKey: .outputResolution)
        try container.encodeIfPresent(sourceFraming, forKey: .sourceFraming)
        try container.encodeIfPresent(transitionStyle, forKey: .transitionStyle)
        try container.encodeIfPresent(transitionDuration, forKey: .transitionDuration)
        try container.encodeIfPresent(snapshot, forKey: .snapshot)
        try container.encode(createdAt, forKey: .createdAt)
    }

    /// Create a deep copy with fresh effect instances for export.
    /// This prevents export from sharing mutable state with preview.
    public func copyForExport() -> Hypnogram {
        Hypnogram(
            compositions: compositions.map { $0.copyForExport() },
            currentCompositionIndex: currentCompositionIndex,
            aspectRatio: aspectRatio,
            outputResolution: outputResolution,
            sourceFraming: sourceFraming,
            transitionStyle: transitionStyle,
            transitionDuration: transitionDuration,
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
