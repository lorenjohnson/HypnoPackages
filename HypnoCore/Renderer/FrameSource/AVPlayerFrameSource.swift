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
import QuartzCore

/// Frame source that pulls frames from an AVPlayer via AVPlayerItemVideoOutput.
/// AVPlayer handles decoding and A/V sync; we pull frames at display cadence.
public final class AVPlayerFrameSource: FrameSource {

    // MARK: - Properties

    /// The underlying AVPlayer
    public let player: AVPlayer

    /// Video output for pulling frames
    private var videoOutput: AVPlayerItemVideoOutput?

    /// The item that currently has `videoOutput` attached (for clean removal on swap)
    private weak var attachedItem: AVPlayerItem?

    /// Observe player.currentItem so we can attach output even when items are swapped externally.
    private var currentItemObservation: NSKeyValueObservation?

    /// Cache the last frame so callers can keep displaying when no new buffer is ready.
    private let cacheLock = NSLock()
    private var cachedFrame: DecodedFrame?

    /// Host time when we last successfully pulled a new pixel buffer.
    private var lastNewBufferHostTime: CFTimeInterval = 0

    /// Host time when we last attempted to reattach the output (stall recovery).
    private var lastReattachAttemptHostTime: CFTimeInterval = 0

    /// Output pixel buffer settings
    /// Using BGRA since FrameCompositor (AVVideoCompositing) outputs BGRA via CIContext.
    /// When no custom compositor is used, AVFoundation will convert to BGRA anyway.
    private let outputSettings: [String: Any] = [
        kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
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

        observeCurrentItem()
    }

    /// Create a frame source with a new AVPlayer
    public convenience init() {
        self.init(player: AVPlayer())
    }

    // MARK: - Configuration

    private func observeCurrentItem() {
        currentItemObservation = player.observe(\.currentItem, options: [.initial, .new]) { [weak self] _, change in
            guard let self else { return }
            guard let item = (change.newValue ?? nil) else {
                self.detachOutput()
                self.updateMetadata(from: nil)
                self.clearCachedFrame()
                return
            }

            self.attachOutput(to: item)
            self.clearCachedFrame()
        }
    }

    private func clearCachedFrame() {
        cacheLock.lock()
        cachedFrame = nil
        cacheLock.unlock()
    }

    /// Detach video output from the previously attached item, if any.
    private func detachOutput() {
        guard let existing = videoOutput else { return }
        attachedItem?.remove(existing)
        attachedItem = nil
        videoOutput = nil
    }

    /// Attach video output to a player item.
    private func attachOutput(to item: AVPlayerItem) {
        // Remove existing output from prior item, if any.
        if let existing = videoOutput {
            attachedItem?.remove(existing)
        }

        // Create new output
        let output = AVPlayerItemVideoOutput(pixelBufferAttributes: outputSettings)
        // We pull frames via the output; AVPlayer's own video rendering isn't used.
        // (Audio continues regardless of this flag.)
        output.suppressesPlayerRendering = true

        item.add(output)
        videoOutput = output
        attachedItem = item

        // Update cached metadata
        updateMetadata(from: item)
    }

    /// If the underlying AVFoundation video pipeline stalls (audio continues but no new pixel buffers),
    /// reattach the video output to nudge it back into producing frames.
    ///
    /// This happens rarely but can show up during rapid edits/transitions where AVFoundation
    /// tears down and rebuilds internal pipelines. We keep it conservative and rate-limited
    /// to avoid thrashing.
    private func recoverFromVideoOutputStallIfNeeded(hostTime: CFTimeInterval) {
        guard let output = videoOutput else { return }
        guard let item = player.currentItem else { return }
        guard item.status == .readyToPlay else { return }
        guard player.rate != 0 else { return } // only when playing

        // If we've *ever* seen a buffer, but now it's been a while, attempt recovery.
        let stallThreshold: CFTimeInterval = 0.75
        let minRetryInterval: CFTimeInterval = 1.5
        guard lastNewBufferHostTime > 0 else { return }
        guard (hostTime - lastNewBufferHostTime) >= stallThreshold else { return }
        guard (hostTime - lastReattachAttemptHostTime) >= minRetryInterval else { return }

        // If AVFoundation says there isn't a new buffer at the current host time, and we've
        // exceeded the stall threshold, reattach.
        let itemTime = output.itemTime(forHostTime: hostTime)
        guard itemTime.isValid, itemTime.isNumeric else { return }
        guard !output.hasNewPixelBuffer(forItemTime: itemTime) else { return }

        lastReattachAttemptHostTime = hostTime
        detachOutput()
        attachOutput(to: item)
        clearCachedFrame()
    }

    /// Configure with a new player item (replaces current item)
    public func configure(with item: AVPlayerItem) {
        player.replaceCurrentItem(with: item)
    }

    /// Update cached metadata from player item
    private func updateMetadata(from item: AVPlayerItem?) {
        guard let item else {
            _naturalSize = .zero
            _duration = .invalid
            return
        }

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
        let hostTime = CACurrentMediaTime()
        let itemTime = output.itemTime(forHostTime: hostTime)
        if output.hasNewPixelBuffer(forItemTime: itemTime) {
            return true
        }
        cacheLock.lock()
        let hasCached = cachedFrame != nil
        cacheLock.unlock()
        return hasCached
    }

    public var naturalSize: CGSize {
        _naturalSize
    }

    public var duration: CMTime {
        _duration
    }

    public func prepare(at time: CMTime) {
        // For AVPlayer-based source, seeking handles preparation
        clearCachedFrame()
        player.seek(to: time, toleranceBefore: .zero, toleranceAfter: .zero)
    }

    public func bestFrame(for targetPTS: CMTime) -> DecodedFrame? {
        guard let output = videoOutput else { return nil }

        var actualTime = CMTime.zero
        guard let pixelBuffer = output.copyPixelBuffer(forItemTime: targetPTS, itemTimeForDisplay: &actualTime) else {
            cacheLock.lock()
            let cached = cachedFrame
            cacheLock.unlock()
            return cached
        }

        // Get color space (CVImageBufferGetColorSpace returns Unmanaged, need to unwrap)
        let colorSpace: CGColorSpace? = CVImageBufferGetColorSpace(pixelBuffer)?.takeUnretainedValue()

        let frame = DecodedFrame(
            pixelBuffer: pixelBuffer,
            pts: actualTime,
            duration: nil,
            isKeyframe: false,  // AVPlayer doesn't expose this
            colorSpace: colorSpace
        )
        cacheLock.lock()
        cachedFrame = frame
        cacheLock.unlock()
        return frame
    }

    public func bestFrame(forHostTime hostTime: CFTimeInterval) -> DecodedFrame? {
        guard let output = videoOutput else { return nil }

        let itemTime = output.itemTime(forHostTime: hostTime)
        guard itemTime.isValid, itemTime.isNumeric else {
            cacheLock.lock()
            let cached = cachedFrame
            cacheLock.unlock()
            return cached
        }

        if !output.hasNewPixelBuffer(forItemTime: itemTime) {
            recoverFromVideoOutputStallIfNeeded(hostTime: hostTime)
            cacheLock.lock()
            let cached = cachedFrame
            cacheLock.unlock()
            return cached
        }

        var actualTime = CMTime.zero
        guard let pixelBuffer = output.copyPixelBuffer(forItemTime: itemTime, itemTimeForDisplay: &actualTime) else {
            cacheLock.lock()
            let cached = cachedFrame
            cacheLock.unlock()
            return cached
        }

        lastNewBufferHostTime = hostTime

        let colorSpace: CGColorSpace? = CVImageBufferGetColorSpace(pixelBuffer)?.takeUnretainedValue()

        let frame = DecodedFrame(
            pixelBuffer: pixelBuffer,
            pts: actualTime,
            duration: nil,
            isKeyframe: false,
            colorSpace: colorSpace
        )
        cacheLock.lock()
        cachedFrame = frame
        cacheLock.unlock()
        return frame
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
        clearCachedFrame()
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

    deinit {
        currentItemObservation?.invalidate()
        detachOutput()
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
