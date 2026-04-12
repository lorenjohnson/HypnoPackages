//
//  SequenceRenderPlan.swift
//  HypnoCore
//
//  Canonical forward sequence-time model shared by future preview and export paths.
//

import CoreMedia
import Foundation

/// A forward sequence-time plan for a full hypnogram.
///
/// This is intentionally a small first slice toward a unified render pipeline:
/// it codifies how a saved sequence maps global sequence time into either
/// composition body playback or an overlap transition between compositions.
public struct SequenceRenderPlan {

    public struct FrameRequest {
        public let frameIndex: Int
        public let presentationTime: CMTime
        public let sample: Sample
    }

    public struct BoundaryTransition {
        public let outgoingCompositionIndex: Int
        public let outgoingCompositionID: UUID
        public let incomingCompositionIndex: Int
        public let incomingCompositionID: UUID
        public let style: TransitionRenderer.TransitionType
        public let duration: CMTime
        public let sequenceStartTime: CMTime
        public let sequenceEndTime: CMTime
    }

    public struct CompositionEntry {
        public let compositionIndex: Int
        public let compositionID: UUID
        public let sequenceStartTime: CMTime
        public let bodyStartTime: CMTime
        public let sequenceEndTime: CMTime
        public let compositionDuration: CMTime
        public let incomingTransitionDuration: CMTime
        public let outgoingTransitionDuration: CMTime

        public var bodyDuration: CMTime {
            CMTimeSubtract(
                CMTimeSubtract(compositionDuration, incomingTransitionDuration),
                outgoingTransitionDuration
            )
        }
    }

    public struct CompositionSample {
        public let sequenceTime: CMTime
        public let compositionIndex: Int
        public let compositionID: UUID
        public let compositionTime: CMTime
    }

    public struct TransitionSample {
        public let sequenceTime: CMTime
        public let outgoingCompositionIndex: Int
        public let outgoingCompositionID: UUID
        public let outgoingCompositionTime: CMTime
        public let incomingCompositionIndex: Int
        public let incomingCompositionID: UUID
        public let incomingCompositionTime: CMTime
        public let style: TransitionRenderer.TransitionType
        public let duration: CMTime
        public let progress: Double
    }

    public enum Sample {
        case composition(CompositionSample)
        case transition(TransitionSample)
    }

    private enum Segment {
        case composition(CompositionSampleTemplate)
        case transition(TransitionSampleTemplate)
    }

    private struct CompositionSampleTemplate {
        let sequenceStartTime: CMTime
        let sequenceEndTime: CMTime
        let compositionIndex: Int
        let compositionID: UUID
        let compositionTimeStart: CMTime
    }

    private struct TransitionSampleTemplate {
        let sequenceStartTime: CMTime
        let sequenceEndTime: CMTime
        let outgoingCompositionIndex: Int
        let outgoingCompositionID: UUID
        let outgoingCompositionTimeStart: CMTime
        let incomingCompositionIndex: Int
        let incomingCompositionID: UUID
        let style: TransitionRenderer.TransitionType
        let duration: CMTime
    }

    public let entries: [CompositionEntry]
    public let transitions: [BoundaryTransition]
    public let totalDuration: CMTime

    private let segments: [Segment]

    private static let timescale: CMTimeScale = 600

    public init(hypnogram: Hypnogram) {
        let compositions = hypnogram.compositions

        guard !compositions.isEmpty else {
            entries = []
            transitions = []
            segments = []
            totalDuration = .zero
            return
        }

        var builtEntries: [CompositionEntry] = []
        var builtTransitions: [BoundaryTransition] = []
        var builtSegments: [Segment] = []

        var bodyStartSeconds: Double = 0
        var previousTransitionDurationSeconds: Double = 0

        for index in compositions.indices {
            let composition = compositions[index]
            let compositionDurationSeconds = Self.normalizedSeconds(composition.effectiveDuration)
            let outgoingTransition = Self.effectiveOutgoingTransition(
                for: index,
                in: compositions,
                hypnogramDefaultStyle: hypnogram.transitionStyle,
                hypnogramDefaultDuration: hypnogram.transitionDuration
            )

            let incomingTransitionSeconds = previousTransitionDurationSeconds
            let outgoingTransitionSeconds = outgoingTransition?.duration.seconds ?? 0
            let appearanceStartSeconds = max(0, bodyStartSeconds - incomingTransitionSeconds)
            let bodyDurationSeconds = max(
                0,
                compositionDurationSeconds - incomingTransitionSeconds - outgoingTransitionSeconds
            )
            let bodyEndSeconds = bodyStartSeconds + bodyDurationSeconds
            let sequenceEndSeconds = appearanceStartSeconds + compositionDurationSeconds

            let entry = CompositionEntry(
                compositionIndex: index,
                compositionID: composition.id,
                sequenceStartTime: Self.time(appearanceStartSeconds),
                bodyStartTime: Self.time(bodyStartSeconds),
                sequenceEndTime: Self.time(sequenceEndSeconds),
                compositionDuration: Self.time(compositionDurationSeconds),
                incomingTransitionDuration: Self.time(incomingTransitionSeconds),
                outgoingTransitionDuration: Self.time(outgoingTransitionSeconds)
            )
            builtEntries.append(entry)

            if bodyDurationSeconds > 0 {
                builtSegments.append(
                    .composition(
                        CompositionSampleTemplate(
                            sequenceStartTime: Self.time(bodyStartSeconds),
                            sequenceEndTime: Self.time(bodyEndSeconds),
                            compositionIndex: index,
                            compositionID: composition.id,
                            compositionTimeStart: Self.time(incomingTransitionSeconds)
                        )
                    )
                )
            }

            if let outgoingTransition {
                let transitionStartSeconds = bodyEndSeconds
                let transitionEndSeconds = transitionStartSeconds + outgoingTransition.duration.seconds

                builtTransitions.append(
                    BoundaryTransition(
                        outgoingCompositionIndex: index,
                        outgoingCompositionID: composition.id,
                        incomingCompositionIndex: outgoingTransition.incomingCompositionIndex,
                        incomingCompositionID: compositions[outgoingTransition.incomingCompositionIndex].id,
                        style: outgoingTransition.style,
                        duration: outgoingTransition.duration,
                        sequenceStartTime: Self.time(transitionStartSeconds),
                        sequenceEndTime: Self.time(transitionEndSeconds)
                    )
                )

                builtSegments.append(
                    .transition(
                        TransitionSampleTemplate(
                            sequenceStartTime: Self.time(transitionStartSeconds),
                            sequenceEndTime: Self.time(transitionEndSeconds),
                            outgoingCompositionIndex: index,
                            outgoingCompositionID: composition.id,
                            outgoingCompositionTimeStart: Self.time(compositionDurationSeconds - outgoingTransition.duration.seconds),
                            incomingCompositionIndex: outgoingTransition.incomingCompositionIndex,
                            incomingCompositionID: compositions[outgoingTransition.incomingCompositionIndex].id,
                            style: outgoingTransition.style,
                            duration: outgoingTransition.duration
                        )
                    )
                )
            }

            bodyStartSeconds += max(0, compositionDurationSeconds - incomingTransitionSeconds)
            previousTransitionDurationSeconds = outgoingTransition?.duration.seconds ?? 0
        }

        entries = builtEntries
        transitions = builtTransitions
        segments = builtSegments
        totalDuration = builtEntries.last?.sequenceEndTime ?? .zero
    }

    public func sample(at sequenceTime: CMTime) -> Sample? {
        guard sequenceTime.isValid, sequenceTime.isNumeric else { return nil }
        guard sequenceTime >= .zero, sequenceTime <= totalDuration else { return nil }

        for segment in segments {
            switch segment {
            case .composition(let template):
                guard sequenceTime >= template.sequenceStartTime,
                      sequenceTime < template.sequenceEndTime else { continue }

                let localOffset = CMTimeSubtract(sequenceTime, template.sequenceStartTime)
                return .composition(
                    CompositionSample(
                        sequenceTime: sequenceTime,
                        compositionIndex: template.compositionIndex,
                        compositionID: template.compositionID,
                        compositionTime: CMTimeAdd(template.compositionTimeStart, localOffset)
                    )
                )

            case .transition(let template):
                let isLastExactFrame = sequenceTime == totalDuration && sequenceTime == template.sequenceEndTime
                guard sequenceTime >= template.sequenceStartTime,
                      sequenceTime < template.sequenceEndTime || isLastExactFrame else { continue }

                let localOffset = CMTimeSubtract(sequenceTime, template.sequenceStartTime)
                let progress: Double
                if template.duration.seconds <= 0 {
                    progress = 1
                } else {
                    progress = max(0, min(localOffset.seconds / template.duration.seconds, 1))
                }

                return .transition(
                    TransitionSample(
                        sequenceTime: sequenceTime,
                        outgoingCompositionIndex: template.outgoingCompositionIndex,
                        outgoingCompositionID: template.outgoingCompositionID,
                        outgoingCompositionTime: CMTimeAdd(template.outgoingCompositionTimeStart, localOffset),
                        incomingCompositionIndex: template.incomingCompositionIndex,
                        incomingCompositionID: template.incomingCompositionID,
                        incomingCompositionTime: localOffset,
                        style: template.style,
                        duration: template.duration,
                        progress: progress
                    )
                )
            }
        }

        if sequenceTime == totalDuration, let lastEntry = entries.last {
            return .composition(
                CompositionSample(
                    sequenceTime: sequenceTime,
                    compositionIndex: lastEntry.compositionIndex,
                    compositionID: lastEntry.compositionID,
                    compositionTime: lastEntry.compositionDuration
                )
            )
        }

        return nil
    }

    public func makeFrameRequests(frameRate: Int) -> [FrameRequest] {
        guard frameRate > 0 else { return [] }

        let durationSeconds = totalDuration.seconds
        guard durationSeconds.isFinite, durationSeconds > 0 else { return [] }

        let frameCount = Int(ceil(durationSeconds * Double(frameRate)))
        let frameDuration = CMTime(value: 1, timescale: CMTimeScale(frameRate))

        return (0..<frameCount).compactMap { frameIndex in
            let presentationTime = CMTimeMultiply(frameDuration, multiplier: Int32(frameIndex))
            guard let sample = sample(at: presentationTime) else { return nil }
            return FrameRequest(
                frameIndex: frameIndex,
                presentationTime: presentationTime,
                sample: sample
            )
        }
    }

    private struct EffectiveOutgoingTransition {
        let incomingCompositionIndex: Int
        let style: TransitionRenderer.TransitionType
        let duration: CMTime
    }

    private static func effectiveOutgoingTransition(
        for compositionIndex: Int,
        in compositions: [Composition],
        hypnogramDefaultStyle: TransitionRenderer.TransitionType?,
        hypnogramDefaultDuration: Double?
    ) -> EffectiveOutgoingTransition? {
        let incomingIndex = compositionIndex + 1
        guard incomingIndex < compositions.count else { return nil }

        let outgoing = compositions[compositionIndex]
        let incoming = compositions[incomingIndex]
        let style = outgoing.transitionStyle ?? hypnogramDefaultStyle ?? .none
        guard style != .none else { return nil }

        let requestedDuration = max(0, outgoing.transitionDuration ?? hypnogramDefaultDuration ?? 0)
        guard requestedDuration > 0 else { return nil }

        let maxDuration = min(
            normalizedSeconds(outgoing.effectiveDuration),
            normalizedSeconds(incoming.effectiveDuration)
        )
        let clampedDuration = min(requestedDuration, maxDuration)
        guard clampedDuration > 0 else { return nil }

        return EffectiveOutgoingTransition(
            incomingCompositionIndex: incomingIndex,
            style: style,
            duration: time(clampedDuration)
        )
    }

    private static func normalizedSeconds(_ time: CMTime) -> Double {
        let seconds = time.seconds
        guard seconds.isFinite else { return 0 }
        return max(0, seconds)
    }

    private static func time(_ seconds: Double) -> CMTime {
        CMTime(seconds: seconds, preferredTimescale: timescale)
    }
}

public extension Hypnogram {
    func makeSequenceRenderPlan() -> SequenceRenderPlan {
        SequenceRenderPlan(hypnogram: self)
    }
}
