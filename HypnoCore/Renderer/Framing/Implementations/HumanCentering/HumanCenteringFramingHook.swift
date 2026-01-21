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
        /// Smoothly blend between bucket-to-bucket results over this duration (seconds).
        /// This reduces visible "jump cuts" when the detected anchor changes.
        public var transitionSmoothingSeconds: Double
        /// When detection is missing, keep the last-known bias for this many seconds (video-time)
        /// before releasing back to centered framing.
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
            transitionSmoothingSeconds: Double = 0.35,
            missHoldSeconds: Double = 1.0,
            deadbandAnchorDelta: CGFloat = 0.03,
            maxAnalysisDimension: CGFloat = 640,
            targetNDC: CGPoint = CGPoint(x: 0, y: 0.92),
            verticalOnly: Bool = true
        ) {
            self.sampleIntervalSeconds = sampleIntervalSeconds
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
    private var cacheOrder: [CacheKey] = []
    private let cacheLock = NSLock()
    private let maxCacheEntries: Int = 4096

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

        // Determine the effective bias for this time (apply miss hold).
        let currentBias = effectiveBias(
            from: currentCached,
            renderID: request.renderID,
            layerIndex: request.layerIndex,
            bucket: bucket,
            outputSize: request.outputSize
        )

        // Blend from previous bucket toward current bucket to reduce visible jumps.
        let previousBias = effectiveBiasForPreviousBucket(
            renderID: request.renderID,
            layerIndex: request.layerIndex,
            bucket: bucket,
            outputSize: request.outputSize
        )

        let smoothed = smoothedBias(
            previous: previousBias,
            current: currentBias,
            at: request.time,
            bucket: bucket,
            intervalSeconds: config.sampleIntervalSeconds,
            smoothingSeconds: config.transitionSmoothingSeconds
        )

        return smoothed
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

        // Basic FIFO eviction to bound memory.
        if cacheOrder.count > maxCacheEntries {
            let overflow = cacheOrder.count - maxCacheEntries
            for _ in 0..<overflow {
                guard let first = cacheOrder.first else { break }
                cacheOrder.removeFirst()
                cache.removeValue(forKey: first)
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

    private func effectiveBias(
        from value: CachedValue,
        renderID: UUID,
        layerIndex: Int,
        bucket: Int,
        outputSize: CGSize
    ) -> FramingBias? {
        switch value {
        case .bias(let bias):
            return bias
        case .none:
            // Hold last known bias for a short period before returning to centered framing.
            guard config.sampleIntervalSeconds > 0 else { return nil }
            let holdBuckets = max(0, Int(ceil(config.missHoldSeconds / config.sampleIntervalSeconds)))
            guard holdBuckets > 0 else { return nil }

            for lookback in 1...holdBuckets {
                let b = bucket - lookback
                if b < 0 { break }
                let key = CacheKey(
                    renderID: renderID,
                    layerIndex: layerIndex,
                    bucket: b,
                    outputW: Int(outputSize.width.rounded(.toNearestOrEven)),
                    outputH: Int(outputSize.height.rounded(.toNearestOrEven))
                )
                if let cached = cachedValue(for: key),
                   case .bias(let prior) = cached {
                    return prior
                }
            }
            return nil
        }
    }

    private func effectiveBiasForPreviousBucket(
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
        guard let prevCached = cachedValue(for: prevKey) else { return nil }
        return effectiveBias(
            from: prevCached,
            renderID: renderID,
            layerIndex: layerIndex,
            bucket: bucket - 1,
            outputSize: outputSize
        )
    }

    private func smoothedBias(
        previous: FramingBias?,
        current: FramingBias?,
        at time: CMTime,
        bucket: Int,
        intervalSeconds: Double,
        smoothingSeconds: Double
    ) -> FramingBias? {
        // If both are nil, remain centered.
        if previous == nil, current == nil { return nil }

        // Apply deadband: if movement is small, keep the previous bias to reduce jitter.
        if let previous, let current {
            let dy = abs(current.anchorNormalized.y - previous.anchorNormalized.y)
            let dx = abs(current.anchorNormalized.x - previous.anchorNormalized.x)
            if max(dx, dy) < config.deadbandAnchorDelta {
                return previous
            }
        }

        guard intervalSeconds > 0, smoothingSeconds > 0 else {
            return current ?? previous
        }

        let seconds = time.seconds
        guard seconds.isFinite, seconds >= 0 else {
            return current ?? previous
        }

        let bucketStart = Double(bucket) * intervalSeconds
        let tInBucket = max(0, seconds - bucketStart)
        let t = min(1.0, tInBucket / smoothingSeconds)

        // Treat nil as "centered" for smooth release.
        let prevBias = previous ?? centeredBias()
        let curBias = current ?? centeredBias()

        // Interpolate anchor and target. Keep axis policy stable (prefer current's policy).
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

    private func lerp(_ a: CGFloat, _ b: CGFloat, _ t: Double) -> CGFloat {
        let tt = CGFloat(max(0, min(1, t)))
        return a + (b - a) * tt
    }
}
