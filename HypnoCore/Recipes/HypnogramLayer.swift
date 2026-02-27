//
//  HypnogramLayer.swift
//  Hypnograph
//
//  Core, mode-agnostic models for media sources and hypnogram composition.
//

import Foundation
import CoreGraphics

// MARK: - Hypnogram core models

/// One source of a hypnogram: clip + transforms + effects + blend mode.
/// Transforms are user-applied (rotation, scale, etc.) - metadata transforms are computed at runtime.
public struct HypnogramLayer: Codable {
    public var mediaClip: MediaClip
    /// User-applied transforms (rotation, scale, translation). Applied after metadata orientation correction.
    public var transforms: [CGAffineTransform]
    public var blendMode: String?
    /// Per-layer opacity multiplier (0.0 - 1.0). Applied in addition to any blend normalization.
    public var opacity: Double
    /// Per-layer audio mute flag. When true, this layer's audio is excluded from composition mixing.
    public var isMuted: Bool

    /// The effect chain for this source - contains definitions and handles instantiation/application.
    /// Use effectChain.apply() to apply effects. Always non-nil (can be empty chain).
    public var effectChain: EffectChain

    private enum CodingKeys: String, CodingKey {
        case mediaClip, transforms, blendMode, opacity, isMuted, effectChain

        // Legacy keys (Phase 1–3 schema)
        case clip
    }

    public init(
        mediaClip: MediaClip,
        transforms: [CGAffineTransform] = [],
        blendMode: String? = nil,
        opacity: Double = 1.0,
        isMuted: Bool = false,
        effectChain: EffectChain? = nil
    ) {
        self.mediaClip = mediaClip
        self.transforms = transforms
        self.blendMode = blendMode
        self.opacity = opacity
        self.isMuted = isMuted
        self.effectChain = effectChain ?? EffectChain()
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        if let decoded = try container.decodeIfPresent(MediaClip.self, forKey: .mediaClip) {
            mediaClip = decoded
        } else {
            // Temporary migration support (Phase 4, Option A):
            // Prior schema stored MediaClip under the `clip` key.
            mediaClip = try container.decode(MediaClip.self, forKey: .clip)
        }
        let codableTransforms = try container.decodeIfPresent([CodableCGAffineTransform].self, forKey: .transforms) ?? []
        transforms = codableTransforms.map { $0.transform }
        blendMode = try container.decodeIfPresent(String.self, forKey: .blendMode)
        opacity = try container.decodeIfPresent(Double.self, forKey: .opacity) ?? 1.0
        isMuted = try container.decodeIfPresent(Bool.self, forKey: .isMuted) ?? false
        effectChain = try container.decodeIfPresent(EffectChain.self, forKey: .effectChain) ?? EffectChain()
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(mediaClip, forKey: .mediaClip)
        try container.encode(transforms.map { CodableCGAffineTransform($0) }, forKey: .transforms)
        try container.encodeIfPresent(blendMode, forKey: .blendMode)
        try container.encode(opacity, forKey: .opacity)
        try container.encode(isMuted, forKey: .isMuted)
        try container.encode(effectChain, forKey: .effectChain)
    }
}
