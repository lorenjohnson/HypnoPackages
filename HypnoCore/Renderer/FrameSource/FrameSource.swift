//
//  FrameSource.swift
//  HypnoCore
//
//  Protocol defining a source of decoded video frames.
//  Abstracts the difference between AVPlayer-based (Direction A) and
//  AVAssetReader-based (Direction B) frame sources.
//

import CoreMedia
import CoreVideo
import CoreGraphics
import QuartzCore

/// A decoded video frame with metadata
public struct DecodedFrame {
    /// The pixel buffer containing frame data
    public let pixelBuffer: CVPixelBuffer

    /// Presentation timestamp
    public let pts: CMTime

    /// Frame duration (if known)
    public let duration: CMTime?

    /// Whether this is a keyframe
    public let isKeyframe: Bool

    /// Color space of the frame (if known)
    public let colorSpace: CGColorSpace?

    public init(
        pixelBuffer: CVPixelBuffer,
        pts: CMTime,
        duration: CMTime? = nil,
        isKeyframe: Bool = false,
        colorSpace: CGColorSpace? = nil
    ) {
        self.pixelBuffer = pixelBuffer
        self.pts = pts
        self.duration = duration
        self.isKeyframe = isKeyframe
        self.colorSpace = colorSpace
    }

    /// Width of the frame in pixels
    public var width: Int {
        CVPixelBufferGetWidth(pixelBuffer)
    }

    /// Height of the frame in pixels
    public var height: Int {
        CVPixelBufferGetHeight(pixelBuffer)
    }

    /// Pixel format of the frame
    public var pixelFormat: OSType {
        CVPixelBufferGetPixelFormatType(pixelBuffer)
    }

    /// Whether the frame is in YUV format (bi-planar)
    public var isYUV: Bool {
        let format = pixelFormat
        return format == kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange ||
               format == kCVPixelFormatType_420YpCbCr8BiPlanarFullRange ||
               format == kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange ||
               format == kCVPixelFormatType_420YpCbCr10BiPlanarFullRange
    }

    /// Whether the frame uses video range (16-235) vs full range (0-255)
    public var isVideoRange: Bool {
        let format = pixelFormat
        return format == kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange ||
               format == kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange
    }
}

/// Protocol for frame sources used by the Metal playback pipeline.
/// Implementations can wrap AVPlayer (Direction A) or AVAssetReader (Direction B).
public protocol FrameSource: AnyObject {

    /// Prepare for playback around this time (hint for pre-roll)
    func prepare(at time: CMTime)

    /// Get the best available frame for the target presentation time
    func bestFrame(for targetPTS: CMTime) -> DecodedFrame?

    /// Get the best available frame for a host time (typically `CACurrentMediaTime()`).
    ///
    /// AVPlayerItemVideoOutput is host-time driven; sources that can should implement this.
    func bestFrame(forHostTime hostTime: CFTimeInterval) -> DecodedFrame?

    /// Request that frames be decoded/buffered around the target time
    func requestFrames(around targetPTS: CMTime)

    /// Current playback time from the source
    var currentTime: CMTime { get }

    /// Whether the source is ready to provide frames
    var isReady: Bool { get }

    /// Natural size of the video content
    var naturalSize: CGSize { get }

    /// Duration of the content (if known)
    var duration: CMTime { get }
}

/// Default implementations for optional methods
public extension FrameSource {
    func prepare(at time: CMTime) {
        // Default: no-op
    }

    func bestFrame(forHostTime hostTime: CFTimeInterval) -> DecodedFrame? {
        // Default: fall back to the source's current time.
        bestFrame(for: currentTime)
    }

    func requestFrames(around targetPTS: CMTime) {
        // Default: no-op (pull-based sources don't need this)
    }
}
