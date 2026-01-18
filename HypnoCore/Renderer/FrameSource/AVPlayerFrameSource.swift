//
//  AVPlayerFrameSource.swift
//  HypnoCore
//
//  FrameSource implementation using AVPlayer + AVPlayerItemVideoOutput.
//  This is "Direction A" of the Metal playback pipeline: AVPlayer handles
//  decode and A/V sync, we pull frames for Metal rendering.
//

import AVFoundation
import CoreMedia
import CoreVideo

/// Frame source that pulls frames from an AVPlayer via AVPlayerItemVideoOutput.
/// AVPlayer handles decoding and A/V sync; we pull frames at display cadence.
public final class AVPlayerFrameSource: FrameSource {

    // MARK: - Properties

    /// The underlying AVPlayer
    public let player: AVPlayer

    /// Video output for pulling frames
    private var videoOutput: AVPlayerItemVideoOutput?

    /// Output pixel buffer settings
    /// Using bi-planar YUV for efficiency (no CPU-side color conversion)
    private let outputSettings: [String: Any] = [
        kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
        kCVPixelBufferMetalCompatibilityKey as String: true,
        kCVPixelBufferIOSurfacePropertiesKey as String: [:]
    ]

    /// Cached natural size from the video track
    private var _naturalSize: CGSize = .zero

    /// Cached duration
    private var _duration: CMTime = .invalid

    // MARK: - Initialization

    /// Create a frame source with an existing AVPlayer
    public init(player: AVPlayer) {
        self.player = player

        // If player already has an item, attach output
        if let item = player.currentItem {
            attachOutput(to: item)
            updateMetadata(from: item)
        }
    }

    /// Create a frame source with a new AVPlayer
    public convenience init() {
        self.init(player: AVPlayer())
    }

    // MARK: - Configuration

    /// Attach video output to a player item
    public func attachOutput(to item: AVPlayerItem) {
        // Remove existing output if any
        if let existing = videoOutput {
            item.remove(existing)
        }

        // Create new output
        let output = AVPlayerItemVideoOutput(pixelBufferAttributes: outputSettings)
        output.suppressesPlayerRendering = false  // Allow AVPlayer to still render audio

        item.add(output)
        videoOutput = output

        // Update cached metadata
        updateMetadata(from: item)
    }

    /// Configure with a new player item (replaces current item)
    public func configure(with item: AVPlayerItem) {
        attachOutput(to: item)
        player.replaceCurrentItem(with: item)
    }

    /// Update cached metadata from player item
    private func updateMetadata(from item: AVPlayerItem) {
        // Get natural size from video track
        if let track = item.asset.tracks(withMediaType: .video).first {
            _naturalSize = track.naturalSize
            let transform = track.preferredTransform
            // Apply transform to get correct orientation
            if transform.a == 0 {
                _naturalSize = CGSize(width: _naturalSize.height, height: _naturalSize.width)
            }
        }

        // Cache duration
        _duration = item.asset.duration
    }

    // MARK: - FrameSource Protocol

    public var currentTime: CMTime {
        player.currentTime()
    }

    public var isReady: Bool {
        guard let output = videoOutput else { return false }
        let time = player.currentTime()
        return output.hasNewPixelBuffer(forItemTime: time)
    }

    public var naturalSize: CGSize {
        _naturalSize
    }

    public var duration: CMTime {
        _duration
    }

    public func prepare(at time: CMTime) {
        // For AVPlayer-based source, seeking handles preparation
        player.seek(to: time, toleranceBefore: .zero, toleranceAfter: .zero)
    }

    public func bestFrame(for targetPTS: CMTime) -> DecodedFrame? {
        guard let output = videoOutput else { return nil }

        var actualTime = CMTime.zero
        guard let pixelBuffer = output.copyPixelBuffer(forItemTime: targetPTS, itemTimeForDisplay: &actualTime) else {
            return nil
        }

        // Get color space (CVImageBufferGetColorSpace returns Unmanaged, need to unwrap)
        let colorSpace: CGColorSpace? = CVImageBufferGetColorSpace(pixelBuffer)?.takeUnretainedValue()

        return DecodedFrame(
            pixelBuffer: pixelBuffer,
            pts: actualTime,
            duration: nil,
            isKeyframe: false,  // AVPlayer doesn't expose this
            colorSpace: colorSpace
        )
    }

    // MARK: - Playback Control (convenience pass-through)

    /// Start playback
    public func play() {
        player.play()
    }

    /// Pause playback
    public func pause() {
        player.pause()
    }

    /// Set playback rate
    public func setRate(_ rate: Float) {
        player.rate = rate
    }

    /// Seek to time
    public func seek(to time: CMTime, completion: ((Bool) -> Void)? = nil) {
        player.seek(to: time, toleranceBefore: .zero, toleranceAfter: .zero) { finished in
            completion?(finished)
        }
    }

    /// Current playback rate
    public var rate: Float {
        get { player.rate }
        set { player.rate = newValue }
    }

    /// Volume (0.0 to 1.0)
    public var volume: Float {
        get { player.volume }
        set { player.volume = newValue }
    }

    /// Whether audio is muted
    public var isMuted: Bool {
        get { player.isMuted }
        set { player.isMuted = newValue }
    }

    /// Audio output device (nil = system default)
    public var audioOutputDeviceUniqueID: String? {
        get { player.audioOutputDeviceUniqueID }
        set { player.audioOutputDeviceUniqueID = newValue }
    }
}

// MARK: - Factory Methods

public extension AVPlayerFrameSource {

    /// Create a frame source from a URL
    static func from(url: URL) -> AVPlayerFrameSource {
        let asset = AVURLAsset(url: url)
        let item = AVPlayerItem(asset: asset)
        let player = AVPlayer(playerItem: item)
        let source = AVPlayerFrameSource(player: player)
        source.attachOutput(to: item)
        return source
    }

    /// Create a frame source from an existing AVPlayerItem
    static func from(item: AVPlayerItem) -> AVPlayerFrameSource {
        let player = AVPlayer(playerItem: item)
        let source = AVPlayerFrameSource(player: player)
        source.attachOutput(to: item)
        return source
    }
}
