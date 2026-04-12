//
//  SequenceRenderPlan.swift
//  HypnoCore
//
//  Canonical forward sequence-time model shared by preview-adjacent features and export.
//

import CoreMedia
import Foundation

/// A forward sequence-time plan for a full hypnogram.
///
/// The plan codifies how saved sequence time maps into either composition body
/// playback or an overlap transition between compositions.
public struct SequenceRenderPlan {

    public struct CompositionBodySpan {
        public let compositionIndex: Int
        public let compositionID: UUID
        public let sequenceStartTime: CMTime
        public let sequenceEndTime: CMTime
        public let compositionTimeStart: CMTime
        public let compositionTimeEnd: CMTime
    }

    public struct TransitionSpan {
        public let outgoingCompositionIndex: Int
        public let outgoingCompositionID: UUID
        public let incomingCompositionIndex: Int
        public let incomingCompositionID: UUID
        public let sequenceStartTime: CMTime
        public let sequenceEndTime: CMTime
        public let outgoingCompositionTimeStart: CMTime
        public let outgoingCompositionTimeEnd: CMTime
        public let incomingCompositionTimeStart: CMTime
        public let incomingCompositionTimeEnd: CMTime
        public let style: TransitionRenderer.TransitionType
        public let duration: CMTime
    }

    public enum Span {
        case compositionBody(CompositionBodySpan)
        case transition(TransitionSpan)
    }

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
    public let orderedSpans: [Span]
    public let totalDuration: CMTime

    private let segments: [Segment]

    private static let timescale: CMTimeScale = 600

    private init(
        entries: [CompositionEntry],
        transitions: [BoundaryTransition],
        orderedSpans: [Span],
        segments: [Segment],
        totalDuration: CMTime
    ) {
        self.entries = entries
        self.transitions = transitions
        self.orderedSpans = orderedSpans
        self.segments = segments
        self.totalDuration = totalDuration
    }

    public init(hypnogram: Hypnogram) {
        let compositions = hypnogram.compositions

        guard !compositions.isEmpty else {
            entries = []
            transitions = []
            orderedSpans = []
            segments = []
            totalDuration = .zero
            return
        }

        var builtEntries: [CompositionEntry] = []
        var builtTransitions: [BoundaryTransition] = []
        var builtOrderedSpans: [Span] = []
        var builtSegments: [Segment] = []

        let outgoingTransitions = Self.resolvedOutgoingTransitions(
            in: compositions,
            hypnogramDefaultStyle: hypnogram.transitionStyle,
            hypnogramDefaultDuration: hypnogram.transitionDuration
        )

        var bodyStartSeconds: Double = 0
        var previousTransitionDurationSeconds: Double = 0

        for index in compositions.indices {
            let composition = compositions[index]
            let compositionDurationSeconds = Self.normalizedSeconds(composition.effectiveDuration)
            let outgoingTransition = outgoingTransitions[index]

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
                builtOrderedSpans.append(
                    .compositionBody(
                        CompositionBodySpan(
                            compositionIndex: index,
                            compositionID: composition.id,
                            sequenceStartTime: Self.time(bodyStartSeconds),
                            sequenceEndTime: Self.time(bodyEndSeconds),
                            compositionTimeStart: Self.time(incomingTransitionSeconds),
                            compositionTimeEnd: Self.time(incomingTransitionSeconds + bodyDurationSeconds)
                        )
                    )
                )

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

                builtOrderedSpans.append(
                    .transition(
                        TransitionSpan(
                            outgoingCompositionIndex: index,
                            outgoingCompositionID: composition.id,
                            incomingCompositionIndex: outgoingTransition.incomingCompositionIndex,
                            incomingCompositionID: compositions[outgoingTransition.incomingCompositionIndex].id,
                            sequenceStartTime: Self.time(transitionStartSeconds),
                            sequenceEndTime: Self.time(transitionEndSeconds),
                            outgoingCompositionTimeStart: Self.time(compositionDurationSeconds - outgoingTransition.duration.seconds),
                            outgoingCompositionTimeEnd: Self.time(compositionDurationSeconds),
                            incomingCompositionTimeStart: .zero,
                            incomingCompositionTimeEnd: outgoingTransition.duration,
                            style: outgoingTransition.style,
                            duration: outgoingTransition.duration
                        )
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

                bodyStartSeconds = transitionEndSeconds
            } else {
                bodyStartSeconds = bodyEndSeconds
            }
            previousTransitionDurationSeconds = outgoingTransition?.duration.seconds ?? 0
        }

        entries = builtEntries
        transitions = builtTransitions
        orderedSpans = builtOrderedSpans
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

    public func alignedToFrameRate(_ frameRate: Int) -> SequenceRenderPlan {
        guard frameRate > 0, !orderedSpans.isEmpty else { return self }

        let frameDuration = CMTime(value: 1, timescale: CMTimeScale(frameRate))

        func snap(_ time: CMTime) -> CMTime {
            let frames = (time.seconds * Double(frameRate)).rounded()
            return CMTimeMultiply(frameDuration, multiplier: Int32(max(0, Int(frames))))
        }

        var alignedSpans: [Span] = []
        alignedSpans.reserveCapacity(orderedSpans.count)

        var cursor = CMTime.zero

        for (index, span) in orderedSpans.enumerated() {
            let rawEnd: CMTime
            let hasPositiveDuration: Bool

            switch span {
            case .compositionBody(let body):
                rawEnd = body.sequenceEndTime
                hasPositiveDuration = body.sequenceEndTime > body.sequenceStartTime

            case .transition(let transition):
                rawEnd = transition.sequenceEndTime
                hasPositiveDuration = transition.sequenceEndTime > transition.sequenceStartTime
            }

            var alignedEnd = index == orderedSpans.count - 1 ? snap(totalDuration) : snap(rawEnd)
            if alignedEnd < cursor {
                alignedEnd = cursor
            }
            if hasPositiveDuration, alignedEnd == cursor {
                alignedEnd = CMTimeAdd(cursor, frameDuration)
            }

            let alignedDuration = CMTimeSubtract(alignedEnd, cursor)

            switch span {
            case .compositionBody(let body):
                alignedSpans.append(
                    .compositionBody(
                        CompositionBodySpan(
                            compositionIndex: body.compositionIndex,
                            compositionID: body.compositionID,
                            sequenceStartTime: cursor,
                            sequenceEndTime: alignedEnd,
                            compositionTimeStart: body.compositionTimeStart,
                            compositionTimeEnd: CMTimeAdd(body.compositionTimeStart, alignedDuration)
                        )
                    )
                )

            case .transition(let transition):
                alignedSpans.append(
                    .transition(
                        TransitionSpan(
                            outgoingCompositionIndex: transition.outgoingCompositionIndex,
                            outgoingCompositionID: transition.outgoingCompositionID,
                            incomingCompositionIndex: transition.incomingCompositionIndex,
                            incomingCompositionID: transition.incomingCompositionID,
                            sequenceStartTime: cursor,
                            sequenceEndTime: alignedEnd,
                            outgoingCompositionTimeStart: transition.outgoingCompositionTimeStart,
                            outgoingCompositionTimeEnd: CMTimeAdd(transition.outgoingCompositionTimeStart, alignedDuration),
                            incomingCompositionTimeStart: transition.incomingCompositionTimeStart,
                            incomingCompositionTimeEnd: CMTimeAdd(transition.incomingCompositionTimeStart, alignedDuration),
                            style: transition.style,
                            duration: alignedDuration
                        )
                    )
                )
            }

            cursor = alignedEnd
        }

        var alignedTransitions: [BoundaryTransition] = []
        var alignedSegments: [Segment] = []

        for span in alignedSpans {
            switch span {
            case .compositionBody(let body):
                alignedSegments.append(
                    .composition(
                        CompositionSampleTemplate(
                            sequenceStartTime: body.sequenceStartTime,
                            sequenceEndTime: body.sequenceEndTime,
                            compositionIndex: body.compositionIndex,
                            compositionID: body.compositionID,
                            compositionTimeStart: body.compositionTimeStart
                        )
                    )
                )

            case .transition(let transition):
                alignedTransitions.append(
                    BoundaryTransition(
                        outgoingCompositionIndex: transition.outgoingCompositionIndex,
                        outgoingCompositionID: transition.outgoingCompositionID,
                        incomingCompositionIndex: transition.incomingCompositionIndex,
                        incomingCompositionID: transition.incomingCompositionID,
                        style: transition.style,
                        duration: transition.duration,
                        sequenceStartTime: transition.sequenceStartTime,
                        sequenceEndTime: transition.sequenceEndTime
                    )
                )

                alignedSegments.append(
                    .transition(
                        TransitionSampleTemplate(
                            sequenceStartTime: transition.sequenceStartTime,
                            sequenceEndTime: transition.sequenceEndTime,
                            outgoingCompositionIndex: transition.outgoingCompositionIndex,
                            outgoingCompositionID: transition.outgoingCompositionID,
                            outgoingCompositionTimeStart: transition.outgoingCompositionTimeStart,
                            incomingCompositionIndex: transition.incomingCompositionIndex,
                            incomingCompositionID: transition.incomingCompositionID,
                            style: transition.style,
                            duration: transition.duration
                        )
                    )
                )
            }
        }

        var bodyByIndex: [Int: CompositionBodySpan] = [:]
        var incomingByIndex: [Int: BoundaryTransition] = [:]
        var outgoingByIndex: [Int: BoundaryTransition] = [:]

        for span in alignedSpans {
            switch span {
            case .compositionBody(let body):
                bodyByIndex[body.compositionIndex] = body
            case .transition(let transition):
                let boundary = BoundaryTransition(
                    outgoingCompositionIndex: transition.outgoingCompositionIndex,
                    outgoingCompositionID: transition.outgoingCompositionID,
                    incomingCompositionIndex: transition.incomingCompositionIndex,
                    incomingCompositionID: transition.incomingCompositionID,
                    style: transition.style,
                    duration: transition.duration,
                    sequenceStartTime: transition.sequenceStartTime,
                    sequenceEndTime: transition.sequenceEndTime
                )
                outgoingByIndex[transition.outgoingCompositionIndex] = boundary
                incomingByIndex[transition.incomingCompositionIndex] = boundary
            }
        }

        let allIndices = Set(entries.map(\.compositionIndex))
        let alignedEntries: [CompositionEntry] = allIndices.sorted().compactMap { index in
            let body = bodyByIndex[index]
            let incoming = incomingByIndex[index]
            let outgoing = outgoingByIndex[index]

            let sequenceStart = incoming?.sequenceStartTime ?? body?.sequenceStartTime ?? outgoing?.sequenceStartTime
            let bodyStart = body?.sequenceStartTime ?? incoming?.sequenceEndTime ?? outgoing?.sequenceStartTime
            let sequenceEnd = outgoing?.sequenceEndTime ?? body?.sequenceEndTime ?? incoming?.sequenceEndTime

            guard let sequenceStart, let bodyStart, let sequenceEnd else { return nil }

            let bodyDuration = body.map { CMTimeSubtract($0.sequenceEndTime, $0.sequenceStartTime) } ?? .zero
            let incomingDuration = incoming?.duration ?? .zero
            let outgoingDuration = outgoing?.duration ?? .zero
            let compositionDuration = CMTimeAdd(CMTimeAdd(incomingDuration, bodyDuration), outgoingDuration)

            let rawEntry = entries.first { $0.compositionIndex == index }

            return CompositionEntry(
                compositionIndex: index,
                compositionID: rawEntry?.compositionID ?? body?.compositionID ?? incoming?.incomingCompositionID ?? outgoing?.outgoingCompositionID ?? UUID(),
                sequenceStartTime: sequenceStart,
                bodyStartTime: bodyStart,
                sequenceEndTime: sequenceEnd,
                compositionDuration: compositionDuration,
                incomingTransitionDuration: incomingDuration,
                outgoingTransitionDuration: outgoingDuration
            )
        }

        return SequenceRenderPlan(
            entries: alignedEntries,
            transitions: alignedTransitions,
            orderedSpans: alignedSpans,
            segments: alignedSegments,
            totalDuration: cursor
        )
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

    private static func resolvedOutgoingTransitions(
        in compositions: [Composition],
        hypnogramDefaultStyle: TransitionRenderer.TransitionType?,
        hypnogramDefaultDuration: Double?
    ) -> [EffectiveOutgoingTransition?] {
        var transitions = compositions.indices.map {
            effectiveOutgoingTransition(
                for: $0,
                in: compositions,
                hypnogramDefaultStyle: hypnogramDefaultStyle,
                hypnogramDefaultDuration: hypnogramDefaultDuration
            )
        }

        guard compositions.count > 2 else { return transitions }

        let durations = compositions.map { normalizedSeconds($0.effectiveDuration) }
        let epsilon = 1e-9

        for _ in 0..<(compositions.count * 2) {
            var changed = false

            for index in compositions.indices {
                let incomingDuration = index > 0 ? (transitions[index - 1]?.duration.seconds ?? 0) : 0
                let outgoingDuration = index < compositions.count - 1 ? (transitions[index]?.duration.seconds ?? 0) : 0
                let totalTransitionDuration = incomingDuration + outgoingDuration
                let compositionDuration = durations[index]

                guard compositionDuration > 0,
                      totalTransitionDuration > compositionDuration + epsilon else {
                    continue
                }

                let scale = compositionDuration / totalTransitionDuration

                if index > 0, let incoming = transitions[index - 1] {
                    let scaledIncomingSeconds = time(incoming.duration.seconds * scale).seconds
                    transitions[index - 1] = EffectiveOutgoingTransition(
                        incomingCompositionIndex: incoming.incomingCompositionIndex,
                        style: incoming.style,
                        duration: time(scaledIncomingSeconds)
                    )
                }

                if index < compositions.count - 1, let outgoing = transitions[index] {
                    let resolvedIncomingSeconds = transitions[index - 1]?.duration.seconds ?? 0
                    let remainingOutgoingSeconds = max(0, compositionDuration - resolvedIncomingSeconds)
                    let scaledOutgoingSeconds = min(
                        time(outgoing.duration.seconds * scale).seconds,
                        remainingOutgoingSeconds
                    )
                    transitions[index] = EffectiveOutgoingTransition(
                        incomingCompositionIndex: outgoing.incomingCompositionIndex,
                        style: outgoing.style,
                        duration: time(scaledOutgoingSeconds)
                    )
                }

                changed = true
            }

            if !changed { break }
        }

        return transitions.map { transition in
            guard let transition, transition.duration.seconds > epsilon else { return nil }
            return transition
        }
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
