//
//  SequenceRenderInstruction.swift
//  HypnoCore
//
//  Instruction format for plan-driven sequence export spans.
//

import AVFoundation
import CoreGraphics
import CoreImage
import Foundation

struct CompositionRenderPass {
    let timeRange: CMTimeRange
    let compositionTimeStart: CMTime
    let layerTrackIDs: [CMPersistentTrackID]
    let blendModes: [String]
    let transforms: [CGAffineTransform]
    let sourceIndices: [Int]
    let enableEffects: Bool
    let stillImages: [CIImage?]
    let sourceFraming: SourceFraming
    let framingHook: (any FramingHook)?
    let renderID: UUID
    let effectManager: EffectManager?
    let applyHypnogramEffectsFromManager: Bool

    func localTime(for sequenceTime: CMTime) -> CMTime {
        let offset = CMTimeSubtract(sequenceTime, timeRange.start)
        return CMTimeAdd(compositionTimeStart, offset)
    }
}

final class SequenceRenderInstruction: NSObject, AVVideoCompositionInstructionProtocol, @unchecked Sendable {
    let timeRange: CMTimeRange
    let enablePostProcessing: Bool = true
    let containsTweening: Bool
    let requiredSourceTrackIDs: [NSValue]?
    let passthroughTrackID: CMPersistentTrackID = kCMPersistentTrackID_Invalid

    let plan: SequenceRenderPlan
    let passesByIndex: [Int: CompositionRenderPass]
    let sequenceEffectManager: EffectManager?

    init(
        timeRange: CMTimeRange,
        containsTweening: Bool,
        plan: SequenceRenderPlan,
        passesByIndex: [Int: CompositionRenderPass],
        sequenceEffectManager: EffectManager?
    ) {
        self.timeRange = timeRange
        self.containsTweening = containsTweening
        self.plan = plan
        self.passesByIndex = passesByIndex
        self.sequenceEffectManager = sequenceEffectManager

        let trackIDs = passesByIndex.values.flatMap(\.layerTrackIDs)

        let uniqueTrackIDs = Array(NSOrderedSet(array: trackIDs.map { NSNumber(value: $0) })) as? [NSNumber] ?? []
        self.requiredSourceTrackIDs = uniqueTrackIDs

        super.init()
    }
}
