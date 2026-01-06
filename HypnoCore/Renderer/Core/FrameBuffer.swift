//
//  FrameBuffer.swift
//  Hypnograph
//
//  GPU-efficient ring buffer for temporal effects.
//  Stores CVPixelBuffers backed by IOSurface for zero-copy GPU access.
//  Extracted from RenderHooks.swift as part of effects architecture refactor.
//

import CoreGraphics
import CoreMedia
import CoreImage
import CoreVideo
import Metal
import AVFoundation

/// GPU-efficient ring buffer for temporal effects.
/// Stores CVPixelBuffers backed by IOSurface for zero-copy GPU access.
/// Supports up to 120 frames (~4 seconds at 30fps) for advanced datamosh/AI effects.
final class FrameBuffer {

    // MARK: - Configuration

    /// Maximum buffer capacity (default 120 for full datamosh/AI support)
    let maxFrames: Int

    /// Current active capacity (can be reduced for lighter effects)
    private(set) var activeCapacity: Int

    /// When true, buffer wraps around for looping clips instead of clearing on time discontinuity.
    /// When requesting frames beyond what's available, wraps to end of buffer (simulating clip loop).
    /// Toggle this to test looping vs non-looping behavior for temporal effects.
    static let loopingModeEnabled: Bool = true

    // MARK: - Storage

    /// Ring buffer of pixel buffers (IOSurface-backed for GPU sharing)
    private var buffers: [CVPixelBuffer?]

    /// Write position in the ring buffer
    private var writeIndex: Int = 0

    /// Number of valid frames currently stored
    private var validCount: Int = 0

    /// Last frame time for discontinuity detection
    private var lastTime: CMTime?

    /// Thread-safe access
    private let queue = DispatchQueue(label: "FrameBuffer.queue")

    /// Pixel buffer pool for efficient allocation
    private var pixelBufferPool: CVPixelBufferPool?

    /// Current buffer dimensions
    private var bufferWidth: Int = 0
    private var bufferHeight: Int = 0

    // MARK: - Init

    /// Initialize with maximum capacity
    /// - Parameter maxFrames: Maximum frames to store (default 120 for ~4s at 30fps)
    init(maxFrames: Int = 120) {
        self.maxFrames = maxFrames
        self.activeCapacity = maxFrames
        self.buffers = Array(repeating: nil, count: maxFrames)
    }

    // MARK: - Pool Management

    /// Create or recreate the pixel buffer pool for the given dimensions
    private func ensurePool(width: Int, height: Int) {
        if bufferWidth == width && bufferHeight == height && pixelBufferPool != nil {
            return
        }

        // Flush old pool before creating new one to release memory
        if let oldPool = pixelBufferPool {
            CVPixelBufferPoolFlush(oldPool, [.excessBuffers])
        }

        bufferWidth = width
        bufferHeight = height

        let poolAttributes: [String: Any] = [
            kCVPixelBufferPoolMinimumBufferCountKey as String: maxFrames
        ]

        let pixelBufferAttributes: [String: Any] = [
            kCVPixelBufferWidthKey as String: width,
            kCVPixelBufferHeightKey as String: height,
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferIOSurfacePropertiesKey as String: [:],  // Enable IOSurface backing
            kCVPixelBufferMetalCompatibilityKey as String: true
        ]

        var pool: CVPixelBufferPool?
        let status = CVPixelBufferPoolCreate(
            kCFAllocatorDefault,
            poolAttributes as CFDictionary,
            pixelBufferAttributes as CFDictionary,
            &pool
        )

        if status == kCVReturnSuccess {
            pixelBufferPool = pool
        } else {
            print("⚠️ FrameBuffer: Failed to create pixel buffer pool: \(status)")
            pixelBufferPool = nil
        }
    }

    /// Get a pixel buffer from the pool
    private func getPooledBuffer() -> CVPixelBuffer? {
        guard let pool = pixelBufferPool else { return nil }

        var pixelBuffer: CVPixelBuffer?
        let status = CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, pool, &pixelBuffer)

        if status != kCVReturnSuccess {
            print("⚠️ FrameBuffer: Failed to get buffer from pool: \(status)")
            return nil
        }

        return pixelBuffer
    }

    // MARK: - Frame Operations

    /// Add a frame to the buffer
    /// - Parameters:
    ///   - image: The CIImage to store
    ///   - time: Frame timestamp (for discontinuity detection)
    func addFrame(_ image: CIImage, at time: CMTime) {
        let extent = image.extent
        guard extent.width > 0, extent.height > 0 else { return }

        let width = Int(extent.width)
        let height = Int(extent.height)

        queue.sync {
            // Detect discontinuity (seek/loop)
            // In looping mode, preserve buffer across loops for continuous effects
            // In non-looping mode, clear buffer when time jumps backwards
            if let last = lastTime, time < last, !Self.loopingModeEnabled {
                clearInternal()
            }
            lastTime = time

            // Ensure pool is configured for current dimensions
            ensurePool(width: width, height: height)

            // Get a buffer from the pool
            guard let pixelBuffer = getPooledBuffer() else { return }

            // Render CIImage directly to the pixel buffer (GPU-efficient)
            SharedRenderer.ciContext.render(
                image,
                to: pixelBuffer,
                bounds: extent,
                colorSpace: CGColorSpaceCreateDeviceRGB()
            )

            // Store in ring buffer
            buffers[writeIndex] = pixelBuffer
            writeIndex = (writeIndex + 1) % activeCapacity
            validCount = min(validCount + 1, activeCapacity)
        }
    }

    /// Get previous frame as CIImage (offset: 1 = previous, 2 = two frames ago, etc.)
    /// In looping mode, wraps around if offset exceeds available frames.
    func previousFrame(offset: Int = 1) -> CIImage? {
        queue.sync {
            guard offset > 0, validCount > 0 else { return nil }

            // In looping mode, wrap offset to available frames
            // This simulates continuous looping where "before the start" wraps to "end of clip"
            let effectiveOffset: Int
            if Self.loopingModeEnabled && offset > validCount {
                effectiveOffset = ((offset - 1) % validCount) + 1
            } else if offset > validCount {
                return nil
            } else {
                effectiveOffset = offset
            }

            // Calculate read position (writeIndex - 1 is most recent)
            let readIndex = (writeIndex - effectiveOffset + activeCapacity) % activeCapacity

            guard let pixelBuffer = buffers[readIndex] else { return nil }

            // Wrap CVPixelBuffer in CIImage (zero-copy - shares IOSurface)
            return CIImage(cvPixelBuffer: pixelBuffer)
        }
    }

    /// Get the most recently added frame
    var currentFrame: CIImage? {
        queue.sync {
            guard validCount > 0 else { return nil }
            let readIndex = (writeIndex - 1 + activeCapacity) % activeCapacity
            guard let pixelBuffer = buffers[readIndex] else { return nil }
            return CIImage(cvPixelBuffer: pixelBuffer)
        }
    }

    /// Check if buffer has minimum frames for temporal effects
    var isFilled: Bool {
        queue.sync {
            validCount >= min(3, activeCapacity)
        }
    }

    /// Number of valid frames currently stored
    var frameCount: Int {
        queue.sync { validCount }
    }

    /// Clear all stored frames
    func clear() {
        queue.sync { clearInternal() }
    }

    private func clearInternal() {
        let previousCount = validCount
        for i in 0..<buffers.count {
            buffers[i] = nil
        }
        writeIndex = 0
        validCount = 0
        lastTime = nil

        // Flush texture cache to release any cached Metal textures from old pixel buffers
        Self.flushTextureCache()

        // Flush excess buffers from pool to reclaim memory
        if let pool = pixelBufferPool {
            CVPixelBufferPoolFlush(pool, [.excessBuffers])
        }

        print("🔄 FrameBuffer: cleared \(previousCount) frames, flushed texture cache and pool")
    }

    // MARK: - Capacity Control

    /// Set active capacity (for effects that need fewer frames)
    /// - Parameter capacity: New capacity (clamped to maxFrames)
    func setActiveCapacity(_ capacity: Int) {
        queue.sync {
            let newCapacity = min(max(1, capacity), maxFrames)
            if newCapacity != activeCapacity {
                // Clear and resize
                clearInternal()
                activeCapacity = newCapacity
            }
        }
    }

    /// Memory estimate in bytes
    var estimatedMemoryUsage: Int {
        queue.sync {
            validCount * bufferWidth * bufferHeight * 4  // 4 bytes per BGRA pixel
        }
    }

    // MARK: - Pre-roll

    /// Pre-roll the buffer by extracting frames from a video asset before playback starts.
    /// This fills the buffer so effects have full history from frame 1.
    /// - Parameters:
    ///   - asset: The video asset to extract frames from
    ///   - startTime: Where playback will begin (frames before this are extracted)
    ///   - frameCount: Number of frames to pre-roll (default: activeCapacity)
    ///   - frameRate: Frame rate for extraction (default: 30)
    /// - Returns: Number of frames successfully pre-rolled
    @discardableResult
    func preroll(from asset: AVAsset, startTime: CMTime, frameCount: Int? = nil, frameRate: Double = 30) async -> Int {
        let targetCount = min(frameCount ?? activeCapacity, activeCapacity)
        guard targetCount > 0 else { return 0 }

        // Get asset duration and video track
        guard let duration = try? await asset.load(.duration),
              let videoTrack = try? await asset.loadTracks(withMediaType: .video).first else {
            print("⚠️ FrameBuffer: Failed to load asset for preroll")
            return 0
        }

        // Calculate start time for extraction
        // We want to extract `targetCount` frames ending at `startTime`
        let frameDuration = CMTime(seconds: 1.0 / frameRate, preferredTimescale: 600)
        let prerollDuration = CMTimeMultiply(frameDuration, multiplier: Int32(targetCount))
        var extractionStart = startTime - prerollDuration

        // Handle wrapping for looping mode
        if Self.loopingModeEnabled && extractionStart < .zero {
            // Wrap to end of clip
            let wrappedSeconds = duration.seconds + extractionStart.seconds.truncatingRemainder(dividingBy: duration.seconds)
            extractionStart = CMTime(seconds: max(0, wrappedSeconds), preferredTimescale: 600)
        } else if extractionStart < .zero {
            extractionStart = .zero
        }

        // Set up AVAssetReader for fast sequential reading
        guard let reader = try? AVAssetReader(asset: asset) else {
            print("⚠️ FrameBuffer: Failed to create AVAssetReader")
            return 0
        }

        // Configure output for BGRA pixel buffers (compatible with CIImage)
        let outputSettings: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA
        ]

        let readerOutput = AVAssetReaderTrackOutput(track: videoTrack, outputSettings: outputSettings)
        readerOutput.alwaysCopiesSampleData = false  // Zero-copy when possible

        guard reader.canAdd(readerOutput) else {
            print("⚠️ FrameBuffer: Cannot add reader output")
            return 0
        }
        reader.add(readerOutput)

        // Set time range for extraction
        let timeRange = CMTimeRange(start: extractionStart, duration: prerollDuration)
        reader.timeRange = timeRange

        // Clear buffer before pre-roll
        clear()

        // Start reading
        guard reader.startReading() else {
            print("⚠️ FrameBuffer: Failed to start reading: \(reader.error?.localizedDescription ?? "unknown")")
            return 0
        }

        var prerolledCount = 0
        let startTimestamp = CACurrentMediaTime()

        // Read frames sequentially (much faster than AVAssetImageGenerator)
        while prerolledCount < targetCount {
            guard let sampleBuffer = readerOutput.copyNextSampleBuffer() else {
                break  // No more samples
            }

            guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else {
                continue
            }

            let presentationTime = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
            let ciImage = CIImage(cvPixelBuffer: pixelBuffer)
            addFrame(ciImage, at: presentationTime)
            prerolledCount += 1
        }

        reader.cancelReading()  // Clean up

        let elapsed = CACurrentMediaTime() - startTimestamp
        print("🎬 FrameBuffer: Pre-rolled \(prerolledCount)/\(targetCount) frames in \(String(format: "%.2f", elapsed))s")
        return prerolledCount
    }

    /// Pre-fill the buffer with copies of a still image.
    /// Used for still images so effects have full history from frame 1.
    /// - Parameters:
    ///   - image: The still image to fill with
    ///   - frameCount: Number of frames to fill (default: activeCapacity)
    /// - Returns: Number of frames filled
    @discardableResult
    func prefill(with image: CIImage, frameCount: Int? = nil) -> Int {
        let targetCount = min(frameCount ?? activeCapacity, activeCapacity)
        guard targetCount > 0 else { return 0 }

        // Clear buffer before pre-fill
        clear()

        // Add the same image multiple times with incrementing fake timestamps
        for i in 0..<targetCount {
            let fakeTime = CMTime(value: CMTimeValue(i), timescale: 30)
            addFrame(image, at: fakeTime)
        }

        print("🖼️ FrameBuffer: Pre-filled \(targetCount) frames with still image")
        return targetCount
    }

    // MARK: - Metal Texture Access

    /// Texture cache for CVPixelBuffer -> MTLTexture conversion
    private static var textureCache: CVMetalTextureCache? = {
        guard let device = SharedRenderer.metalDevice else { return nil }
        var cache: CVMetalTextureCache?
        CVMetalTextureCacheCreate(kCFAllocatorDefault, nil, device, nil, &cache)
        return cache
    }()

    /// Flush the texture cache (call when clearing buffer to release old textures)
    static func flushTextureCache() {
        if let cache = textureCache {
            CVMetalTextureCacheFlush(cache, 0)
        }
    }

    /// Get previous frame as MTLTexture for Metal compute shaders
    /// - Parameter offset: History offset (1 = previous frame, 2 = two frames ago, etc.)
    /// - Returns: MTLTexture backed by the same IOSurface (zero-copy)
    /// In looping mode, wraps around if offset exceeds available frames.
    func previousTexture(offset: Int = 1) -> MTLTexture? {
        queue.sync {
            guard offset > 0, validCount > 0 else { return nil }

            // In looping mode, wrap offset to available frames
            let effectiveOffset: Int
            if Self.loopingModeEnabled && offset > validCount {
                effectiveOffset = ((offset - 1) % validCount) + 1
            } else if offset > validCount {
                return nil
            } else {
                effectiveOffset = offset
            }

            let readIndex = (writeIndex - effectiveOffset + activeCapacity) % activeCapacity
            guard let pixelBuffer = buffers[readIndex] else { return nil }

            return textureFromPixelBuffer(pixelBuffer)
        }
    }

    /// Get texture at specific history offset (thread-safe)
    /// - Parameter offset: How far back in history (0 = most recent)
    func texture(atHistoryOffset offset: Int) -> MTLTexture? {
        return previousTexture(offset: offset + 1)  // previousTexture uses 1-based offset
    }

    /// Current buffer dimensions
    var currentWidth: Int { queue.sync { bufferWidth } }
    var currentHeight: Int { queue.sync { bufferHeight } }

    /// Convert CVPixelBuffer to MTLTexture (zero-copy via IOSurface)
    private func textureFromPixelBuffer(_ pixelBuffer: CVPixelBuffer) -> MTLTexture? {
        guard let cache = Self.textureCache else { return nil }

        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)

        var cvTexture: CVMetalTexture?
        let status = CVMetalTextureCacheCreateTextureFromImage(
            kCFAllocatorDefault,
            cache,
            pixelBuffer,
            nil,
            .bgra8Unorm,
            width,
            height,
            0,
            &cvTexture
        )

        guard status == kCVReturnSuccess, let cvTex = cvTexture else {
            return nil
        }

        return CVMetalTextureGetTexture(cvTex)
    }
}
