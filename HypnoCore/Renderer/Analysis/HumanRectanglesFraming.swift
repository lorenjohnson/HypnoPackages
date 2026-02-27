//
//  HumanRectanglesFraming.swift
//  HypnoCore
//
//  Vision-based human detection for content-aware framing.
//

import AVFoundation
import CoreImage
import CoreMedia
import CoreGraphics
import ImageIO
import Vision

public enum HumanRectanglesFraming {

    public struct Config: Sendable {
        public var targetNDC: CGPoint
        public var minimumHumanConfidence: Float
        public var minimumHumanArea: CGFloat
        public var detectFaces: Bool
        public var minimumFaceConfidence: Float
        public var minimumFaceArea: CGFloat
        public var faceScoreBoost: Float

        public init(
            targetNDC: CGPoint = CGPoint(x: 0, y: 0.92),
            minimumHumanConfidence: Float = 0.20,
            minimumHumanArea: CGFloat = 0.005,
            detectFaces: Bool = true,
            minimumFaceConfidence: Float = 0.20,
            minimumFaceArea: CGFloat = 0.001,
            faceScoreBoost: Float = 2.0
        ) {
            self.targetNDC = targetNDC
            self.minimumHumanConfidence = minimumHumanConfidence
            self.minimumHumanArea = minimumHumanArea
            self.detectFaces = detectFaces
            self.minimumFaceConfidence = minimumFaceConfidence
            self.minimumFaceArea = minimumFaceArea
            self.faceScoreBoost = faceScoreBoost
        }
    }

    public struct Observation: Sendable, Equatable {
        public var boundingBox: CGRect
        public var confidence: Float

        public init(boundingBox: CGRect, confidence: Float) {
            self.boundingBox = boundingBox
            self.confidence = confidence
        }
    }

    public struct Analysis: Sendable, Equatable {
        public var hasPerson: Bool
        public var bestObservation: Observation?
        public var contentFocus: RendererView.ContentFocus?

        public init(hasPerson: Bool, bestObservation: Observation?, contentFocus: RendererView.ContentFocus?) {
            self.hasPerson = hasPerson
            self.bestObservation = bestObservation
            self.contentFocus = contentFocus
        }
    }

    public static func analyze(
        asset: AVAsset,
        videoComposition: AVVideoComposition? = nil,
        sampleTimes: [CMTime]? = nil,
        config: Config = Config()
    ) -> Analysis {
        let times = sampleTimes ?? defaultSampleTimes(for: asset.duration)

        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero
        if let videoComposition {
            generator.videoComposition = videoComposition
        }

        var best: (obs: Observation, score: Float)?

        for time in times {
            guard let cgImage = try? generator.copyCGImage(at: time, actualTime: nil) else { continue }
            guard let observation = bestHumanObservation(in: cgImage, config: config) else { continue }

            let area = observation.boundingBox.width * observation.boundingBox.height
            let score = observation.confidence * Float(area)
            if let currentBest = best {
                if score > currentBest.score { best = (observation, score) }
            } else {
                best = (observation, score)
            }
        }

        guard let bestObs = best?.obs else {
            return Analysis(hasPerson: false, bestObservation: nil, contentFocus: nil)
        }

        let focus = RendererView.ContentFocus(
            anchorNormalized: CGPoint(x: bestObs.boundingBox.midX, y: bestObs.boundingBox.maxY),
            targetNDC: config.targetNDC,
            boundsNormalized: bestObs.boundingBox,
            paddingNDC: 0,
            overscrollMode: .clampToEdges
        )

        return Analysis(hasPerson: true, bestObservation: bestObs, contentFocus: focus)
    }

    public static func analyze(
        pixelBuffer: CVPixelBuffer,
        orientation: CGImagePropertyOrientation = .up,
        config: Config = Config()
    ) -> Analysis {
        let faceObs: Observation? = {
            guard config.detectFaces else { return nil }
            return bestFaceObservation(in: pixelBuffer, orientation: orientation, config: config)
        }()

        let humanObs: Observation? = bestHumanObservation(in: pixelBuffer, orientation: orientation, config: config)

        // Prefer using face for the anchor (stable head reference), but use the human rect
        // as the bounds when available so we can shift further to include more body.
        guard faceObs != nil || humanObs != nil else {
            return Analysis(hasPerson: false, bestObservation: nil, contentFocus: nil)
        }

        let anchorSource = faceObs ?? humanObs!
        let boundsSource = humanObs ?? faceObs!

        let focus = RendererView.ContentFocus(
            anchorNormalized: CGPoint(x: anchorSource.boundingBox.midX, y: anchorSource.boundingBox.maxY),
            targetNDC: config.targetNDC,
            boundsNormalized: boundsSource.boundingBox,
            paddingNDC: 0,
            overscrollMode: .clampToEdges
        )

        return Analysis(hasPerson: true, bestObservation: boundsSource, contentFocus: focus)
    }

    public static func analyze(
        ciImage: CIImage,
        config: Config = Config(),
        maxDimension: CGFloat = 640
    ) -> Analysis {
        var image = ciImage
        if image.extent.origin != .zero {
            image = image.transformed(by: CGAffineTransform(translationX: -image.extent.origin.x, y: -image.extent.origin.y))
        }

        let w = image.extent.width
        let h = image.extent.height
        guard w > 0, h > 0 else {
            return Analysis(hasPerson: false, bestObservation: nil, contentFocus: nil)
        }

        let maxDim = max(w, h)
        let scale = maxDim > maxDimension ? (maxDimension / maxDim) : 1
        if scale != 1 {
            image = image.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        }

        guard let cgImage = SharedRenderer.ciContext.createCGImage(image, from: image.extent) else {
            return Analysis(hasPerson: false, bestObservation: nil, contentFocus: nil)
        }

        return analyze(cgImage: cgImage, orientation: .up, config: config)
    }

    public static func analyze(
        cgImage: CGImage,
        orientation: CGImagePropertyOrientation = .up,
        config: Config = Config()
    ) -> Analysis {
        let faceObs: Observation? = {
            guard config.detectFaces else { return nil }
            return bestFaceObservation(in: cgImage, orientation: orientation, config: config)
        }()

        let humanObs: Observation? = bestHumanObservation(in: cgImage, orientation: orientation, config: config)

        guard faceObs != nil || humanObs != nil else {
            return Analysis(hasPerson: false, bestObservation: nil, contentFocus: nil)
        }

        let anchorSource = faceObs ?? humanObs!
        let boundsSource = humanObs ?? faceObs!

        let focus = RendererView.ContentFocus(
            anchorNormalized: CGPoint(x: anchorSource.boundingBox.midX, y: anchorSource.boundingBox.maxY),
            targetNDC: config.targetNDC,
            boundsNormalized: boundsSource.boundingBox,
            paddingNDC: 0,
            overscrollMode: .clampToEdges
        )

        return Analysis(hasPerson: true, bestObservation: boundsSource, contentFocus: focus)
    }

    private static func bestHumanObservation(in cgImage: CGImage, config: Config) -> Observation? {
        bestHumanObservation(in: cgImage, orientation: .up, config: config)
    }

    private static func bestHumanObservation(
        in cgImage: CGImage,
        orientation: CGImagePropertyOrientation,
        config: Config
    ) -> Observation? {
        let request = VNDetectHumanRectanglesRequest()
        request.upperBodyOnly = false

        let handler = VNImageRequestHandler(cgImage: cgImage, orientation: orientation, options: [:])
        do {
            try handler.perform([request])
        } catch {
            return nil
        }

        let humans: [VNHumanObservation] = (request.results as? [VNHumanObservation]) ?? []

        var best: Observation?
        var bestScore: Float = 0

        for human in humans {
            let bbox = human.boundingBox
            let area = bbox.width * bbox.height
            let confidence = human.confidence

            guard confidence >= config.minimumHumanConfidence else { continue }
            guard area >= config.minimumHumanArea else { continue }

            let score = confidence * Float(area)
            if best == nil || score > bestScore {
                best = Observation(boundingBox: bbox, confidence: confidence)
                bestScore = score
            }
        }

        return best
    }

    private static func bestHumanObservation(
        in pixelBuffer: CVPixelBuffer,
        orientation: CGImagePropertyOrientation,
        config: Config
    ) -> Observation? {
        let request = VNDetectHumanRectanglesRequest()
        request.upperBodyOnly = false

        let handler = VNImageRequestHandler(cvPixelBuffer: pixelBuffer, orientation: orientation, options: [:])
        do {
            try handler.perform([request])
        } catch {
            return nil
        }

        let humans: [VNHumanObservation] = (request.results as? [VNHumanObservation]) ?? []

        var best: Observation?
        var bestScore: Float = 0

        for human in humans {
            let bbox = human.boundingBox
            let area = bbox.width * bbox.height
            let confidence = human.confidence

            guard confidence >= config.minimumHumanConfidence else { continue }
            guard area >= config.minimumHumanArea else { continue }

            let score = confidence * Float(area)
            if best == nil || score > bestScore {
                best = Observation(boundingBox: bbox, confidence: confidence)
                bestScore = score
            }
        }

        return best
    }

    private static func bestFaceObservation(
        in pixelBuffer: CVPixelBuffer,
        orientation: CGImagePropertyOrientation,
        config: Config
    ) -> Observation? {
        let request = VNDetectFaceRectanglesRequest()

        let handler = VNImageRequestHandler(cvPixelBuffer: pixelBuffer, orientation: orientation, options: [:])
        do {
            try handler.perform([request])
        } catch {
            return nil
        }

        let faces: [VNFaceObservation] = (request.results as? [VNFaceObservation]) ?? []

        var best: Observation?
        var bestScore: Float = 0

        for face in faces {
            let bbox = face.boundingBox
            let area = bbox.width * bbox.height
            let confidence = face.confidence

            guard confidence >= config.minimumFaceConfidence else { continue }
            guard area >= config.minimumFaceArea else { continue }

            let score = confidence * Float(area)
            if best == nil || score > bestScore {
                best = Observation(boundingBox: bbox, confidence: confidence)
                bestScore = score
            }
        }

        return best
    }

    private static func bestFaceObservation(
        in cgImage: CGImage,
        orientation: CGImagePropertyOrientation,
        config: Config
    ) -> Observation? {
        let request = VNDetectFaceRectanglesRequest()

        let handler = VNImageRequestHandler(cgImage: cgImage, orientation: orientation, options: [:])
        do {
            try handler.perform([request])
        } catch {
            return nil
        }

        let faces: [VNFaceObservation] = (request.results as? [VNFaceObservation]) ?? []

        var best: Observation?
        var bestScore: Float = 0

        for face in faces {
            let bbox = face.boundingBox
            let area = bbox.width * bbox.height
            let confidence = face.confidence

            guard confidence >= config.minimumFaceConfidence else { continue }
            guard area >= config.minimumFaceArea else { continue }

            let score = confidence * Float(area)
            if best == nil || score > bestScore {
                best = Observation(boundingBox: bbox, confidence: confidence)
                bestScore = score
            }
        }

        return best
    }

    private static func defaultSampleTimes(for duration: CMTime) -> [CMTime] {
        guard duration.isValid, duration.isNumeric else { return [.zero] }
        let seconds = duration.seconds
        guard seconds.isFinite, seconds > 0 else { return [.zero] }

        let t0 = 0.0
        let t1 = min(0.5, seconds * 0.10)
        let t2 = min(1.0, seconds * 0.33)

        let all = [t0, t1, t2]
            .filter { $0 >= 0 && $0 <= seconds }
            .map { CMTime(seconds: $0, preferredTimescale: 600) }

        // Deduplicate (times can collapse for very short clips).
        var unique: [CMTime] = []
        for t in all where !unique.contains(where: { $0 == t }) {
            unique.append(t)
        }
        return unique.isEmpty ? [.zero] : unique
    }
}
