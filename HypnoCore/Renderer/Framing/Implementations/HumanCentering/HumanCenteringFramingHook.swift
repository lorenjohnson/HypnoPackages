//
//  HumanCenteringFramingHook.swift
//  HypnoCore
//
//  Vision-backed framing hook that biases aspect-fill crops toward detected humans/faces.
//

import Foundation
import CoreGraphics
import CoreImage
import CoreMedia

public final class HumanCenteringFramingHook: FramingHook {

    public struct Config: Sendable {
        /// Sampling interval in seconds (video-time). The hook computes at most one Vision analysis per bucket.
        public var sampleIntervalSeconds: Double
        /// Low-pass filter time constant (seconds). Larger values = more damping/lag, fewer jumps.
        public var dampingTimeConstantSeconds: Double
        /// Smoothly blend between bucket-to-bucket results over this duration (seconds).
        /// This reduces visible "jump cuts" when the detected anchor changes.
        public var transitionSmoothingSeconds: Double
        /// When detection is missing, keep the last-known bias for this many seconds (video-time)
        /// before releasing back to centered framing (smoothly; never a hard snap).
        public var missHoldSeconds: Double
        /// Ignore small anchor changes below this threshold (normalized units) to reduce jitter.
        public var deadbandAnchorDelta: CGFloat
        /// Downscale limit for Vision analysis.
        public var maxAnalysisDimension: CGFloat
        /// Desired target position for the subject anchor in output NDC space (-1...1).
        public var targetNDC: CGPoint
        /// Whether to restrict movement to vertical-only (portrait→landscape is the common case).
        public var verticalOnly: Bool

        public init(
            sampleIntervalSeconds: Double = 0.5,
            dampingTimeConstantSeconds: Double = 1.0,
            transitionSmoothingSeconds: Double = 0.35,
            missHoldSeconds: Double = 1.0,
            deadbandAnchorDelta: CGFloat = 0.03,
            maxAnalysisDimension: CGFloat = 640,
            targetNDC: CGPoint = CGPoint(x: 0, y: 0.92),
            verticalOnly: Bool = true
        ) {
            self.sampleIntervalSeconds = sampleIntervalSeconds
            self.dampingTimeConstantSeconds = dampingTimeConstantSeconds
            self.transitionSmoothingSeconds = transitionSmoothingSeconds
            self.missHoldSeconds = missHoldSeconds
            self.deadbandAnchorDelta = deadbandAnchorDelta
            self.maxAnalysisDimension = maxAnalysisDimension
            self.targetNDC = targetNDC
            self.verticalOnly = verticalOnly
        }
    }

    public static let shared = HumanCenteringFramingHook()

    private let config: Config

    private struct CacheKey: Hashable {
        var renderID: UUID
        var layerIndex: Int
        var bucket: Int
        var outputW: Int
        var outputH: Int
    }

    private enum CachedValue: Sendable {
        case none
        case bias(FramingBias)
    }

    private var cache: [CacheKey: CachedValue] = [:]
    private var smoothedCache: [CacheKey: CachedValue] = [:]
    private var cacheOrder: [CacheKey] = []
    private let cacheLock = NSLock()
    private let maxCacheEntries: Int = 4096

    private struct StreamKey: Hashable {
        var renderID: UUID
        var layerIndex: Int
        var outputW: Int
        var outputH: Int
    }

    private var lastDetectedBucketByStream: [StreamKey: Int] = [:]

    public init(config: Config = Config()) {
        self.config = config
    }

    public func framingBias(for request: FramingRequest) -> FramingBias? {
        guard request.sourceFraming == .fill else { return nil }

        // Quick reject: if there is no slack after aspect-fill, we can't translate without revealing edges.
        if !hasSlackForAspectFill(sourceExtent: request.sourceImage.extent, outputSize: request.outputSize) {
            return nil
        }

        let bucket = timeBucket(for: request.time, intervalSeconds: config.sampleIntervalSeconds)
        let key = CacheKey(
            renderID: request.renderID,
            layerIndex: request.layerIndex,
            bucket: bucket,
            outputW: Int(request.outputSize.width.rounded(.toNearestOrEven)),
            outputH: Int(request.outputSize.height.rounded(.toNearestOrEven))
        )

        // Ensure we have a cached value (bias or miss) for this time bucket.
        let currentCached: CachedValue = cachedValue(for: key) ?? {
            let analysisConfig = HumanRectanglesFraming.Config(targetNDC: config.targetNDC)
            let analysis = HumanRectanglesFraming.analyze(
                ciImage: request.sourceImage,
                config: analysisConfig,
                maxDimension: config.maxAnalysisDimension
            )

            let bias: FramingBias? = {
                guard let obs = analysis.bestObservation else { return nil }

                // Anchor at the top-center of the best observation (head-ish). Clamp to bounds.
                let anchor = CGPoint(
                    x: max(0, min(1, obs.boundingBox.midX)),
                    y: max(0, min(1, obs.boundingBox.maxY))
                )

                return FramingBias(
                    anchorNormalized: config.verticalOnly ? CGPoint(x: 0.5, y: anchor.y) : anchor,
                    boundsNormalized: obs.boundingBox,
                    targetNDC: config.targetNDC,
                    axisPolicy: config.verticalOnly ? .verticalOnly : .both
                )
            }()

            let value: CachedValue = bias.map { .bias($0) } ?? .none
            storeValue(value, for: key)
            return value
        }()

        noteDetectionIfPresent(currentCached, for: key)

        // Smooth/dampen across buckets (deterministic) and never "snap back to center" after a miss:
        // if detection fails for a bucket, hold the prior smoothed bias.
        let currentSmoothed = smoothedBiasForBucket(
            key: key,
            raw: currentCached,
            outputSize: request.outputSize
        )

        let previousSmoothed = smoothedBiasForPreviousBucket(
            renderID: request.renderID,
            layerIndex: request.layerIndex,
            bucket: bucket,
            outputSize: request.outputSize
        )

        return inBucketBlend(
            previous: previousSmoothed,
            current: currentSmoothed,
            time: request.time,
            bucket: bucket,
            intervalSeconds: config.sampleIntervalSeconds,
            smoothingSeconds: config.transitionSmoothingSeconds
        )
    }

    private func cachedValue(for key: CacheKey) -> CachedValue? {
        cacheLock.lock()
        defer { cacheLock.unlock() }
        return cache[key]
    }

    private func storeValue(_ value: CachedValue, for key: CacheKey) {
        cacheLock.lock()
        defer { cacheLock.unlock() }

        if cache[key] == nil {
            cacheOrder.append(key)
        }
        cache[key] = value
        smoothedCache.removeValue(forKey: key)

        // Basic FIFO eviction to bound memory.
        if cacheOrder.count > maxCacheEntries {
            let overflow = cacheOrder.count - maxCacheEntries
            for _ in 0..<overflow {
                guard let first = cacheOrder.first else { break }
                cacheOrder.removeFirst()
                cache.removeValue(forKey: first)
                smoothedCache.removeValue(forKey: first)

                let streamKey = StreamKey(
                    renderID: first.renderID,
                    layerIndex: first.layerIndex,
                    outputW: first.outputW,
                    outputH: first.outputH
                )
                if lastDetectedBucketByStream[streamKey] == first.bucket {
                    lastDetectedBucketByStream.removeValue(forKey: streamKey)
                }
            }
        }
    }

    private func timeBucket(for time: CMTime, intervalSeconds: Double) -> Int {
        guard intervalSeconds > 0 else { return 0 }
        let seconds = time.seconds
        guard seconds.isFinite, seconds >= 0 else { return 0 }
        return Int(floor(seconds / intervalSeconds))
    }

    private func hasSlackForAspectFill(sourceExtent: CGRect, outputSize: CGSize) -> Bool {
        let w = sourceExtent.width
        let h = sourceExtent.height
        guard w > 0, h > 0, outputSize.width > 0, outputSize.height > 0 else { return false }

        let scale = max(outputSize.width / w, outputSize.height / h)
        let scaledW = w * scale
        let scaledH = h * scale
        let slackX = scaledW - outputSize.width
        let slackY = scaledH - outputSize.height
        return slackX > 0.5 || slackY > 0.5
    }

    private func noteDetectionIfPresent(_ value: CachedValue, for key: CacheKey) {
        guard case .bias = value else { return }

        let streamKey = StreamKey(
            renderID: key.renderID,
            layerIndex: key.layerIndex,
            outputW: key.outputW,
            outputH: key.outputH
        )

        cacheLock.lock()
        defer { cacheLock.unlock() }
        let existing = lastDetectedBucketByStream[streamKey] ?? Int.min
        lastDetectedBucketByStream[streamKey] = max(existing, key.bucket)
    }

    private func lastDetectedBucket(for key: CacheKey) -> Int? {
        let streamKey = StreamKey(
            renderID: key.renderID,
            layerIndex: key.layerIndex,
            outputW: key.outputW,
            outputH: key.outputH
        )
        cacheLock.lock()
        defer { cacheLock.unlock() }
        return lastDetectedBucketByStream[streamKey]
    }

    private func smoothedCachedValue(for key: CacheKey) -> CachedValue? {
        cacheLock.lock()
        defer { cacheLock.unlock() }
        return smoothedCache[key]
    }

    private func smoothedBiasForPreviousBucket(
        renderID: UUID,
        layerIndex: Int,
        bucket: Int,
        outputSize: CGSize
    ) -> FramingBias? {
        guard bucket > 0 else { return nil }
        let prevKey = CacheKey(
            renderID: renderID,
            layerIndex: layerIndex,
            bucket: bucket - 1,
            outputW: Int(outputSize.width.rounded(.toNearestOrEven)),
            outputH: Int(outputSize.height.rounded(.toNearestOrEven))
        )
        guard let cached = smoothedCachedValue(for: prevKey) else { return nil }
        if case .bias(let bias) = cached { return bias }
        return nil
    }

    private func smoothedBiasForBucket(
        key: CacheKey,
        raw: CachedValue,
        outputSize: CGSize
    ) -> FramingBias? {
        if let existing = smoothedCachedValue(for: key) {
            if case .bias(let bias) = existing { return bias }
            return nil
        }

        // Prev smoothed bias (if available). We only rely on the immediately previous bucket so this is cheap.
        let prev: FramingBias? = smoothedBiasForPreviousBucket(
            renderID: key.renderID,
            layerIndex: key.layerIndex,
            bucket: key.bucket,
            outputSize: outputSize
        )

        let rawBias: FramingBias? = {
            if case .bias(let bias) = raw { return bias }
            return nil
        }()

        // Never jump back to center on a miss: hold the last bias when detection fails.
        let held: FramingBias? = {
            if let rawBias { return rawBias }
            guard let prev else { return nil }

            if config.missHoldSeconds.isFinite, config.missHoldSeconds >= 0,
               let lastDetected = lastDetectedBucket(for: key)
            {
                let bucketsSince = max(0, key.bucket - lastDetected)
                let secondsSince = Double(bucketsSince) * config.sampleIntervalSeconds
                if secondsSince > config.missHoldSeconds {
                    return centeredBias()
                }
            }

            return prev
        }()

        // Deadband against the previous smoothed value to reduce tiny jitter.
        let debanded: FramingBias? = {
            guard let held, let prev else { return held }
            let dy = abs(held.anchorNormalized.y - prev.anchorNormalized.y)
            let dx = abs(held.anchorNormalized.x - prev.anchorNormalized.x)
            if max(dx, dy) < config.deadbandAnchorDelta {
                return prev
            }
            return held
        }()

        let smoothed: FramingBias? = {
            guard let debanded else { return nil }
            guard let prev else { return debanded }

            let alpha = smoothingAlpha(intervalSeconds: config.sampleIntervalSeconds, tau: config.dampingTimeConstantSeconds)
            let anchor = CGPoint(
                x: lerp(prev.anchorNormalized.x, debanded.anchorNormalized.x, alpha),
                y: lerp(prev.anchorNormalized.y, debanded.anchorNormalized.y, alpha)
            )
            let target = CGPoint(
                x: lerp(prev.targetNDC.x, debanded.targetNDC.x, alpha),
                y: lerp(prev.targetNDC.y, debanded.targetNDC.y, alpha)
            )

            return FramingBias(
                anchorNormalized: anchor,
                boundsNormalized: debanded.boundsNormalized ?? prev.boundsNormalized,
                targetNDC: target,
                axisPolicy: debanded.axisPolicy
            )
        }()

        storeSmoothedBias(smoothed, for: key)
        return smoothed
    }

    private func inBucketBlend(
        previous: FramingBias?,
        current: FramingBias?,
        time: CMTime,
        bucket: Int,
        intervalSeconds: Double,
        smoothingSeconds: Double
    ) -> FramingBias? {
        if previous == nil, current == nil { return nil }

        guard intervalSeconds > 0, smoothingSeconds > 0 else {
            return current ?? previous
        }

        let seconds = time.seconds
        guard seconds.isFinite, seconds >= 0 else {
            return current ?? previous
        }

        let bucketStart = Double(bucket) * intervalSeconds
        let tInBucket = max(0, seconds - bucketStart)
        let clampedSmoothing = min(smoothingSeconds, intervalSeconds)
        let tRaw = min(1.0, tInBucket / clampedSmoothing)
        let t = smoothstep(tRaw)

        let prevBias = previous ?? centeredBias()
        let curBias = current ?? prevBias

        let anchor = CGPoint(
            x: lerp(prevBias.anchorNormalized.x, curBias.anchorNormalized.x, t),
            y: lerp(prevBias.anchorNormalized.y, curBias.anchorNormalized.y, t)
        )
        let target = CGPoint(
            x: lerp(prevBias.targetNDC.x, curBias.targetNDC.x, t),
            y: lerp(prevBias.targetNDC.y, curBias.targetNDC.y, t)
        )

        return FramingBias(
            anchorNormalized: anchor,
            boundsNormalized: curBias.boundsNormalized ?? prevBias.boundsNormalized,
            targetNDC: target,
            axisPolicy: curBias.axisPolicy
        )
    }

    private func centeredBias() -> FramingBias {
        FramingBias(
            anchorNormalized: CGPoint(x: 0.5, y: 0.5),
            boundsNormalized: nil,
            targetNDC: CGPoint(x: 0, y: 0),
            axisPolicy: config.verticalOnly ? .verticalOnly : .both
        )
    }

    private func storeSmoothedBias(_ bias: FramingBias?, for key: CacheKey) {
        cacheLock.lock()
        defer { cacheLock.unlock() }
        smoothedCache[key] = bias.map { .bias($0) } ?? .none
    }

    private func smoothingAlpha(intervalSeconds: Double, tau: Double) -> Double {
        guard intervalSeconds > 0 else { return 1.0 }
        guard tau.isFinite, tau > 0 else { return 1.0 }
        return 1.0 - exp(-intervalSeconds / tau)
    }

    private func smoothstep(_ t: Double) -> Double {
        let x = max(0, min(1, t))
        return x * x * (3 - 2 * x)
    }

    private func lerp(_ a: CGFloat, _ b: CGFloat, _ t: Double) -> CGFloat {
        let tt = CGFloat(max(0, min(1, t)))
        return a + (b - a) * tt
    }
}
