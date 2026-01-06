//
//  HypnogramSource.swift
//  Hypnograph
//
//  Core, mode-agnostic models for media sources and hypnogram composition.
//

import Foundation
import CoreGraphics

// MARK: - Hypnogram core models

/// One source of a hypnogram: clip + transforms + effects + blend mode.
/// Transforms are user-applied (rotation, scale, etc.) - metadata transforms are computed at runtime.
public struct HypnogramSource: Codable {
    public var clip: VideoClip
    /// User-applied transforms (rotation, scale, translation). Applied after metadata orientation correction.
    public var transforms: [CGAffineTransform]
    public var blendMode: String?

    /// The effect chain for this source - contains definitions and handles instantiation/application.
    /// Use effectChain.apply() to apply effects. Always non-nil (can be empty chain).
    public var effectChain: EffectChain

    private enum CodingKeys: String, CodingKey {
        case clip, transforms, blendMode, effectChain
    }

    public init(
        clip: VideoClip,
        transforms: [CGAffineTransform] = [],
        blendMode: String? = nil,
        effectChain: EffectChain? = nil
    ) {
        self.clip = clip
        self.transforms = transforms
        self.blendMode = blendMode
        self.effectChain = effectChain ?? EffectChain()
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        clip = try container.decode(VideoClip.self, forKey: .clip)
        let codableTransforms = try container.decodeIfPresent([CodableCGAffineTransform].self, forKey: .transforms) ?? []
        transforms = codableTransforms.map { $0.transform }
        blendMode = try container.decodeIfPresent(String.self, forKey: .blendMode)
        effectChain = try container.decodeIfPresent(EffectChain.self, forKey: .effectChain) ?? EffectChain()
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(clip, forKey: .clip)
        try container.encode(transforms.map { CodableCGAffineTransform($0) }, forKey: .transforms)
        try container.encodeIfPresent(blendMode, forKey: .blendMode)
        try container.encode(effectChain, forKey: .effectChain)
    }
}
