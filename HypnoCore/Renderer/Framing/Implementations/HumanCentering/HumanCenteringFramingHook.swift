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
        /// Downscale limit for Vision analysis.
        public var maxAnalysisDimension: CGFloat
        /// Desired target position for the subject anchor in output NDC space (-1...1).
        public var targetNDC: CGPoint
        /// Whether to restrict movement to vertical-only (portrait→landscape is the common case).
        public var verticalOnly: Bool

        public init(
            sampleIntervalSeconds: Double = 0.5,
            maxAnalysisDimension: CGFloat = 640,
            targetNDC: CGPoint = CGPoint(x: 0, y: 0.92),
            verticalOnly: Bool = true
        ) {
            self.sampleIntervalSeconds = sampleIntervalSeconds
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

        if let cached = cachedValue(for: key) {
            switch cached {
            case .none:
                return nil
            case .bias(let bias):
                return bias
            }
        }

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

        storeValue(bias.map { .bias($0) } ?? .none, for: key)
        return bias
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
}
