//
//  SlowMoPipeline.swift
//  Hypnograph
//
//  Lookahead pipeline for realtime slow-mo interpolation.
//  Pre-computes interpolated frames ahead of playback using VTFrameProcessor.
//

import Foundation
import AVFoundation
import CoreVideo
import CoreImage
import VideoToolbox

// MARK: - Shared Pipeline Instance

/// Shared slow-mo pipeline for the app
@available(macOS 15.4, *)
let sharedSlowMoPipeline = SlowMoPipeline()

// MARK: - Slow-Mo Pipeline

/// Manages pre-computation of interpolated frames for realtime slow-mo.
/// Uses an actor for thread-safe state and limits concurrent VT operations.
@available(macOS 15.4, *)
final class SlowMoPipeline: @unchecked Sendable {

    // MARK: - Configuration

    /// How many frames to compute ahead
    private let lookaheadFrames = 4  // Reduced to limit concurrent work

    /// Max concurrent VT operations (VTFrameProcessor is heavy)
    private let maxConcurrentOperations = 2

    /// Maximum frames to keep in cache to limit memory
    private let maxCacheSize = 30

    // MARK: - State (protected by actor-like serial queue)

    /// Serial queue for all state access
    private let stateQueue = DispatchQueue(label: "com.hypnograph.slowmo.state")

    /// VTFrameProcessor instance (reused for session)
    private var processor: VTFrameProcessor?
    private var sessionWidth: Int = 0
    private var sessionHeight: Int = 0

    /// Cache of ready interpolated frames: [outputFrameIndex: buffer]
    private var frameCache: [Int: CVPixelBuffer] = [:]

    /// Track which frames are being computed
    private var pendingFrames: Set<Int> = []

    /// Current number of active VT operations
    private var activeOperations: Int = 0

    /// Source frame storage: [sourceFrameIndex: buffer]
    private var sourceFrames: [Int: CVPixelBuffer] = [:]

    /// Reusable destination buffer pool
    private var bufferPool: CVPixelBufferPool?

    // MARK: - Public Interface (all sync, non-blocking)

    /// Get an interpolated frame if ready, nil otherwise.
    /// This is called from the render thread - must be fast.
    func getFrame(outputFrameIndex: Int) -> CVPixelBuffer? {
        // Use sync on state queue - fast because cache lookup is O(1)
        return stateQueue.sync { frameCache[outputFrameIndex] }
    }

    /// Submit source frames and request interpolation.
    /// Returns immediately - processing happens in background.
    func submitSourceFrames(
        prevBuffer: CVPixelBuffer,
        currentBuffer: CVPixelBuffer,
        prevSourceIndex: Int,
        currentSourceIndex: Int,
        currentOutputIndex: Int,
        playRate: Float
    ) {
        let width = CVPixelBufferGetWidth(currentBuffer)
        let height = CVPixelBufferGetHeight(currentBuffer)

        // Dispatch state update async to not block render thread
        stateQueue.async { [weak self] in
            guard let self = self else { return }

            // Store source frames
            self.sourceFrames[prevSourceIndex] = prevBuffer
            self.sourceFrames[currentSourceIndex] = currentBuffer

            // Clean old source frames (keep last 4 for interpolation flexibility)
            let minIndex = max(0, prevSourceIndex - 2)
            self.sourceFrames = self.sourceFrames.filter { $0.key >= minIndex }

            // Request lookahead frames (limited)
            for offset in 0..<self.lookaheadFrames {
                let targetOutputIndex = currentOutputIndex + offset
                self.requestFrameOnStateQueue(
                    outputIndex: targetOutputIndex,
                    prevSourceIndex: prevSourceIndex,
                    currentSourceIndex: currentSourceIndex,
                    playRate: playRate,
                    width: width,
                    height: height
                )
            }
        }
    }

    /// Clear all cached frames (call on seek or playback reset)
    func reset() {
        stateQueue.async { [weak self] in
            self?.frameCache.removeAll()
            self?.pendingFrames.removeAll()
            self?.sourceFrames.removeAll()
        }
    }

    /// Evict old frames from cache to limit memory
    func evictOldFrames(beforeIndex: Int) {
        stateQueue.async { [weak self] in
            guard let self = self else { return }

            // Remove frames before the specified index
            self.frameCache = self.frameCache.filter { $0.key >= beforeIndex }

            // Also enforce maximum cache size as a safety limit
            if self.frameCache.count > self.maxCacheSize {
                let sortedKeys = self.frameCache.keys.sorted()
                let keysToRemove = sortedKeys.prefix(self.frameCache.count - self.maxCacheSize)
                for key in keysToRemove {
                    self.frameCache.removeValue(forKey: key)
                }
            }

            // Note: sourceFrames are cleaned in submitSourceFrames (keep last 4)
            // Don't clean here to avoid race with in-flight requests
        }
    }

    // MARK: - Private Processing (called on stateQueue)

    /// Request a frame - must be called on stateQueue
    private func requestFrameOnStateQueue(
        outputIndex: Int,
        prevSourceIndex: Int,
        currentSourceIndex: Int,
        playRate: Float,
        width: Int,
        height: Int
    ) {
        // Skip if already cached or pending
        if frameCache[outputIndex] != nil { return }
        if pendingFrames.contains(outputIndex) { return }

        // Limit concurrent operations to avoid overwhelming GPU
        if activeOperations >= maxConcurrentOperations { return }

        pendingFrames.insert(outputIndex)
        activeOperations += 1

        // Get source frames while on state queue
        guard let prev = sourceFrames[prevSourceIndex],
              let current = sourceFrames[currentSourceIndex] else {
            pendingFrames.remove(outputIndex)
            activeOperations -= 1
            return
        }

        // Dispatch async work off the state queue
        Task.detached(priority: .utility) { [weak self] in
            await self?.computeFrameAsync(
                outputIndex: outputIndex,
                prev: prev,
                current: current,
                prevSourceIndex: prevSourceIndex,
                currentSourceIndex: currentSourceIndex,
                playRate: playRate,
                width: width,
                height: height
            )
        }
    }

    /// Compute a frame asynchronously
    private func computeFrameAsync(
        outputIndex: Int,
        prev: CVPixelBuffer,
        current: CVPixelBuffer,
        prevSourceIndex: Int,
        currentSourceIndex: Int,
        playRate: Float,
        width: Int,
        height: Int
    ) async {
        defer {
            // Clean up on state queue
            stateQueue.async { [weak self] in
                self?.pendingFrames.remove(outputIndex)
                self?.activeOperations -= 1
            }
        }

        // Ensure processor session (sync, on state queue)
        let processor: VTFrameProcessor? = stateQueue.sync { [weak self] in
            guard let self = self else { return nil }
            do {
                try self.ensureSessionSync(width: width, height: height)
                return self.processor
            } catch {
                return nil
            }
        }

        guard let processor = processor else { return }

        // Calculate blend factor for this output frame
        let outputsPerSource = 1.0 / Double(playRate)
        let positionInSource = Double(outputIndex).truncatingRemainder(dividingBy: outputsPerSource)
        let blendFactor = Float(positionInSource / outputsPerSource)

        // Create frame wrappers
        let sourceDuration = 1.0 / 30.0  // Assume 30fps source
        let prevPTS = CMTimeMakeWithSeconds(Double(prevSourceIndex) * sourceDuration, preferredTimescale: 600)
        let currentPTS = CMTimeMakeWithSeconds(Double(currentSourceIndex) * sourceDuration, preferredTimescale: 600)

        guard let sourceFrame = VTFrameProcessorFrame(buffer: prev, presentationTimeStamp: prevPTS),
              let nextFrame = VTFrameProcessorFrame(buffer: current, presentationTimeStamp: currentPTS) else {
            return
        }

        // Create destination buffer (on state queue for pool access)
        let destBuffer: CVPixelBuffer? = stateQueue.sync { [weak self] in
            self?.createDestinationBufferSync(width: width, height: height)
        }

        guard let destBuffer = destBuffer else { return }

        let destPTS = CMTimeAdd(prevPTS, CMTimeMultiplyByFloat64(CMTimeSubtract(currentPTS, prevPTS), multiplier: Float64(blendFactor)))
        guard let destFrame = VTFrameProcessorFrame(buffer: destBuffer, presentationTimeStamp: destPTS) else {
            return
        }

        // Create parameters
        guard let params = VTFrameRateConversionParameters(
            sourceFrame: sourceFrame,
            nextFrame: nextFrame,
            opticalFlow: nil,
            interpolationPhase: [blendFactor],
            submissionMode: .sequential,
            destinationFrames: [destFrame]
        ) else {
            return
        }

        // Process (this is the async VT call)
        do {
            try await processor.process(parameters: params)

            // Store result on state queue
            stateQueue.async { [weak self] in
                self?.frameCache[outputIndex] = destBuffer
            }
        } catch {
            // Silently fail - CrossFade will be used as fallback
        }
    }

    /// Ensure session - must be called on stateQueue
    private func ensureSessionSync(width: Int, height: Int) throws {
        // If we already have a matching session, use it
        if processor != nil && sessionWidth == width && sessionHeight == height {
            return
        }

        // If there are active operations, wait - don't create a new session
        // The caller will fail gracefully and use CrossFade
        if activeOperations > 0 {
            throw NSError(domain: "SlowMoPipeline", code: 2, userInfo: [NSLocalizedDescriptionKey: "Session busy"])
        }

        // Create new config
        guard let config = VTFrameRateConversionConfiguration(
            frameWidth: width,
            frameHeight: height,
            usePrecomputedFlow: false,
            qualityPrioritization: .quality,
            revision: .revision1
        ) else {
            throw NSError(domain: "SlowMoPipeline", code: 1, userInfo: [NSLocalizedDescriptionKey: "Configuration failed"])
        }

        // End old session safely (we know no operations are in flight)
        processor?.endSession()
        processor = nil

        let newProcessor = VTFrameProcessor()
        try newProcessor.startSession(configuration: config)

        processor = newProcessor
        sessionWidth = width
        sessionHeight = height
    }

    /// Create destination buffer - must be called on stateQueue
    private func createDestinationBufferSync(width: Int, height: Int) -> CVPixelBuffer? {
        if bufferPool == nil || sessionWidth != width || sessionHeight != height {
            let poolAttrs: [String: Any] = [
                kCVPixelBufferPoolMinimumBufferCountKey as String: lookaheadFrames + 4
            ]
            let bufferAttrs: [String: Any] = [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey as String: width,
                kCVPixelBufferHeightKey as String: height,
                kCVPixelBufferIOSurfacePropertiesKey as String: [:] as CFDictionary
            ]

            var pool: CVPixelBufferPool?
            CVPixelBufferPoolCreate(nil, poolAttrs as CFDictionary, bufferAttrs as CFDictionary, &pool)
            bufferPool = pool
        }

        guard let pool = bufferPool else { return nil }

        var buffer: CVPixelBuffer?
        CVPixelBufferPoolCreatePixelBuffer(nil, pool, &buffer)
        return buffer
    }

    deinit {
        processor?.endSession()
    }
}

