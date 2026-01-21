//
//  FramingRequest.swift
//  HypnoCore
//
//  Inputs passed to a FramingHook.
//

import CoreGraphics
import CoreImage
import CoreMedia

/// Inputs describing a single per-source framing decision.
public struct FramingRequest: Sendable {

    /// Identifies the render session (e.g. one AVPlayerItem / export run).
    public var renderID: UUID

    /// Layer index within the render instruction (bottom-to-top).
    public var layerIndex: Int

    /// Source index in the recipe/clip.
    public var sourceIndex: Int

    /// Composition time being rendered.
    public var time: CMTime

    /// How the source is being mapped into the output frame.
    public var sourceFraming: SourceFraming

    /// Output render size.
    public var outputSize: CGSize

    /// The source image after metadata/user transforms but before SourceFraming is applied.
    /// This is the image the hook should analyze (if needed).
    public var sourceImage: CIImage

    public init(
        renderID: UUID,
        layerIndex: Int,
        sourceIndex: Int,
        time: CMTime,
        sourceFraming: SourceFraming,
        outputSize: CGSize,
        sourceImage: CIImage
    ) {
        self.renderID = renderID
        self.layerIndex = layerIndex
        self.sourceIndex = sourceIndex
        self.time = time
        self.sourceFraming = sourceFraming
        self.outputSize = outputSize
        self.sourceImage = sourceImage
    }
}

