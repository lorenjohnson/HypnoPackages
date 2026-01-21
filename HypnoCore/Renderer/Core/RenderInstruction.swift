//
//  RenderInstruction.swift
//  Hypnograph
//
//  Instruction format for the frame compositor
//

import Foundation
import AVFoundation
import CoreGraphics
import CoreImage

/// Instruction for rendering a time range
/// Tells the compositor which layers to blend, how to transform them, etc.
final class RenderInstruction: NSObject, AVVideoCompositionInstructionProtocol, @unchecked Sendable {
    
    // MARK: - AVVideoCompositionInstructionProtocol
    
    public let timeRange: CMTimeRange
    public let enablePostProcessing: Bool = true
    public let containsTweening: Bool = false
    public let requiredSourceTrackIDs: [NSValue]?
    public let passthroughTrackID: CMPersistentTrackID = kCMPersistentTrackID_Invalid
    
    // MARK: - Custom Properties

    /// Track IDs for each layer (bottom to top)
    public let layerTrackIDs: [CMPersistentTrackID]

    /// Blend mode for each layer (CIBlendMode constant names)
    public let blendModes: [String]

    /// Combined transform for each layer (metadata orientation + user transform)
    public let transforms: [CGAffineTransform]

    /// Map each layer to a source index in the recipe (for effects)
    public let sourceIndices: [Int]

    /// Whether to apply effects
    public let enableEffects: Bool

    /// Still images for layers that are images (indexed by layer, nil for video layers)
    public let stillImages: [CIImage?]

    /// How each source should be mapped into the output frame.
    public let sourceFraming: SourceFraming

    /// Optional hook for per-source framing decisions (smart framing).
    public let framingHook: (any FramingHook)?

    /// Identifies the render session for caching (one AVPlayerItem / export run).
    public let renderID: UUID

    /// The EffectManager to use for effects processing.
    /// - Preview: passes state.effectManager (mutable, changes affect playback)
    /// - Live Display: passes livePlayer.effectManager (isolated instance)
    /// - Export: passes a freshly created manager from recipe.copyForExport()
    public weak var effectManager: EffectManager?

    // MARK: - Initialization

    public init(
        timeRange: CMTimeRange,
        layerTrackIDs: [CMPersistentTrackID],
        blendModes: [String],
        transforms: [CGAffineTransform],
        sourceIndices: [Int],
        enableEffects: Bool = false,
        stillImages: [CIImage?] = [],
        sourceFraming: SourceFraming = .fill,
        framingHook: (any FramingHook)? = nil,
        renderID: UUID = UUID(),
        effectManager: EffectManager? = nil
    ) {
        self.timeRange = timeRange
        self.layerTrackIDs = layerTrackIDs
        self.blendModes = blendModes
        self.transforms = transforms
        self.sourceIndices = sourceIndices
        self.enableEffects = enableEffects
        self.stillImages = stillImages
        self.sourceFraming = sourceFraming
        self.framingHook = framingHook
        self.renderID = renderID
        self.effectManager = effectManager

        // Required track IDs for AVFoundation
        // Must wrap CMPersistentTrackID as NSNumber
        // For still images, we still need track IDs even though tracks are empty
        self.requiredSourceTrackIDs = layerTrackIDs.map { NSNumber(value: $0) }

        super.init()
    }
    
    // MARK: - Debug
    
    public override var description: String {
        let range = "\(timeRange.start.seconds)s → \(timeRange.end.seconds)s"
        let layers = layerTrackIDs.count
        return "RenderInstruction[\(range), \(layers) layers]"
    }
}
