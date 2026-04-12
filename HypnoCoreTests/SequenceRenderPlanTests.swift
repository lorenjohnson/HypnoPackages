import CoreMedia
import Testing
import HypnoCore

struct SequenceRenderPlanTests {

    @Test func noTransitionPlanMapsSequentialCompositionBodies() {
        let hypnogram = Hypnogram(
            compositions: [
                makeComposition(duration: 2),
                makeComposition(duration: 3)
            ]
        )

        let plan = hypnogram.makeSequenceRenderPlan()

        #expect(plan.entries.count == 2)
        #expect(plan.transitions.isEmpty)
        #expect(plan.totalDuration.seconds == 5)

        guard case .composition(let first)? = plan.sample(at: CMTime(seconds: 1.0, preferredTimescale: 600)) else {
            Issue.record("Expected first composition sample")
            return
        }
        #expect(first.compositionIndex == 0)
        #expect(first.compositionTime.seconds == 1.0)

        guard case .composition(let second)? = plan.sample(at: CMTime(seconds: 3.5, preferredTimescale: 600)) else {
            Issue.record("Expected second composition sample")
            return
        }
        #expect(second.compositionIndex == 1)
        #expect(second.compositionTime.seconds == 1.5)
    }

    @Test func compositionOwnedTransitionCreatesOverlapSegment() {
        var first = makeComposition(duration: 5)
        first.transitionStyle = .crossfade
        first.transitionDuration = 1

        let second = makeComposition(duration: 5)

        let hypnogram = Hypnogram(compositions: [first, second])
        let plan = hypnogram.makeSequenceRenderPlan()

        #expect(plan.entries.count == 2)
        #expect(plan.transitions.count == 1)
        #expect(plan.totalDuration.seconds == 9)
        #expect(plan.entries[0].bodyStartTime.seconds == 0)
        #expect(plan.entries[0].bodyDuration.seconds == 4)
        #expect(plan.entries[1].sequenceStartTime.seconds == 4)
        #expect(plan.entries[1].bodyStartTime.seconds == 5)

        guard case .transition(let sample)? = plan.sample(at: CMTime(seconds: 4.5, preferredTimescale: 600)) else {
            Issue.record("Expected transition sample")
            return
        }
        #expect(sample.outgoingCompositionIndex == 0)
        #expect(sample.incomingCompositionIndex == 1)
        #expect(sample.style == .crossfade)
        #expect(sample.outgoingCompositionTime.seconds == 4.5)
        #expect(sample.incomingCompositionTime.seconds == 0.5)
        #expect(sample.progress == 0.5)
    }

    @Test func hypnogramDefaultTransitionIsUsedWhenCompositionHasNoOverride() {
        let hypnogram = Hypnogram(
            compositions: [
                makeComposition(duration: 3),
                makeComposition(duration: 4)
            ],
            transitionStyle: .blur,
            transitionDuration: 0.5
        )

        let plan = hypnogram.makeSequenceRenderPlan()

        #expect(plan.transitions.count == 1)
        #expect(plan.transitions[0].style == .blur)
        #expect(plan.transitions[0].duration.seconds == 0.5)
        #expect(plan.totalDuration.seconds == 6.5)
    }

    @Test func explicitNoneSuppressesHypnogramDefaultTransition() {
        var first = makeComposition(duration: 3)
        first.transitionStyle = TransitionRenderer.TransitionType.none
        first.transitionDuration = 1

        let hypnogram = Hypnogram(
            compositions: [
                first,
                makeComposition(duration: 4)
            ],
            transitionStyle: .crossfade,
            transitionDuration: 0.5
        )

        let plan = hypnogram.makeSequenceRenderPlan()

        #expect(plan.transitions.isEmpty)
        #expect(plan.totalDuration.seconds == 7)
    }

    @Test func transitionDurationIsClampedToShortestAdjacentComposition() {
        var first = makeComposition(duration: 5)
        first.transitionStyle = .crossfade
        first.transitionDuration = 3

        let second = makeComposition(duration: 1)
        let hypnogram = Hypnogram(compositions: [first, second])
        let plan = hypnogram.makeSequenceRenderPlan()

        #expect(plan.transitions.count == 1)
        #expect(plan.transitions[0].duration.seconds == 1)
        #expect(plan.totalDuration.seconds == 5)
    }

    @Test func frameRequestsFollowSequenceTimeAtExportCadence() {
        var first = makeComposition(duration: 2)
        first.transitionStyle = .crossfade
        first.transitionDuration = 0.5

        let second = makeComposition(duration: 2)
        let hypnogram = Hypnogram(compositions: [first, second])
        let plan = hypnogram.makeSequenceRenderPlan()

        let requests = plan.makeFrameRequests(frameRate: 2)

        #expect(requests.count == 7)
        #expect(requests.first?.presentationTime.seconds == 0)
        #expect(requests.last?.presentationTime.seconds == 3.0)

        guard case .composition(let firstBody)? = requests[safe: 2]?.sample else {
            Issue.record("Expected composition sample before overlap")
            return
        }
        #expect(firstBody.compositionIndex == 0)
        #expect(firstBody.compositionTime.seconds == 1.0)

        guard case .transition(let overlap)? = requests[safe: 3]?.sample else {
            Issue.record("Expected transition sample during overlap")
            return
        }
        #expect(overlap.outgoingCompositionIndex == 0)
        #expect(overlap.incomingCompositionIndex == 1)
        #expect(overlap.sequenceTime.seconds == 1.5)
        #expect(overlap.progress == 0.0)

        guard case .composition(let secondBody)? = requests[safe: 4]?.sample else {
            Issue.record("Expected composition sample after overlap")
            return
        }
        #expect(secondBody.compositionIndex == 1)
        #expect(secondBody.compositionTime.seconds == 0.5)
    }

    private func makeComposition(duration seconds: Double) -> Composition {
        Composition(
            layers: [],
            targetDuration: CMTime(seconds: seconds, preferredTimescale: 600)
        )
    }
}

private extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
