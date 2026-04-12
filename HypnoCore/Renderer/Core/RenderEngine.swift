//
//  RenderEngine.swift
//  Hypnograph
//
//  Shared render engine for preview and export.
//

import Foundation
import AVFoundation
import CoreGraphics
import CoreImage

/// Unified render engine for preview and export
public final class RenderEngine {
    
    // MARK: - Configuration

    public struct Config {
        public let outputSize: CGSize
        public let frameRate: Int
        public let enableEffects: Bool
        public let sourceFraming: SourceFraming
        public let framingHook: (any FramingHook)?

        public init(
            outputSize: CGSize,
            frameRate: Int,
            enableEffects: Bool,
            sourceFraming: SourceFraming = .fill,
            framingHook: (any FramingHook)? = HumanCenteringFramingHook.shared
        ) {
            self.outputSize = outputSize
            self.frameRate = frameRate
            self.enableEffects = enableEffects
            self.sourceFraming = sourceFraming
            self.framingHook = framingHook
        }
    }

    public struct CompositionBuildUnit {
        public let compositionIndex: Int
        public let compositionID: UUID
        public let compositionDuration: CMTime
        public let composition: AVComposition
        public let videoComposition: AVVideoComposition
        public let audioMix: AVAudioMix?
        let layerTrackIDs: [CMPersistentTrackID]
        let blendModes: [String]
        let transforms: [CGAffineTransform]
        let sourceIndices: [Int]
        let stillImages: [CIImage?]
        let sourceFraming: SourceFraming
        let framingHook: (any FramingHook)?
        let renderID: UUID
        let effectManager: EffectManager
        let audioTrackBaseVolume: Float
    }

    public struct SequenceBuild {
        public let hypnogram: Hypnogram
        public let plan: SequenceRenderPlan
        public let compositionUnits: [CompositionBuildUnit]
        let sequenceEffectManager: EffectManager
    }
    
    // MARK: - Dependencies
    
    private let compositionBuilder = CompositionBuilder()

    public init() {}

    // MARK: - Runtime Rebinding

    /// Rebind all render instructions in an existing player item to a new effect manager.
    /// Useful when overlapping transitions need independent effect state for outgoing/incoming clips.
    @MainActor
    @discardableResult
    public static func rebindEffectManager(
        _ effectManager: EffectManager,
        on playerItem: AVPlayerItem
    ) -> Bool {
        guard let composition = playerItem.videoComposition else { return false }

        let mutableComposition: AVMutableVideoComposition
        if let direct = composition as? AVMutableVideoComposition {
            mutableComposition = direct
        } else if let copied = composition.mutableCopy() as? AVMutableVideoComposition {
            mutableComposition = copied
        } else {
            return false
        }

        var didUpdate = false
        for instruction in mutableComposition.instructions {
            guard let renderInstruction = instruction as? RenderInstruction else { continue }
            renderInstruction.effectManager = effectManager
            didUpdate = true
        }

        if didUpdate {
            playerItem.videoComposition = mutableComposition
        }
        return didUpdate
    }
    
    // MARK: - Preview

    /// Build a player item for preview or isolated playback
    /// - Parameters:
    ///   - composition: The composition to build
    ///   - config: Render configuration
    ///   - effectManager: The EffectManager to use. If nil, uses composition effect chain
    public func makePlayerItem(
        composition: Composition,
        config: Config,
        effectManager: EffectManager? = nil
    ) async -> Result<AVPlayerItem, RenderError> {

        let buildResult = await compositionBuilder.build(
            composition: composition,
            outputSize: config.outputSize,
            frameRate: config.frameRate,
            enableEffects: config.enableEffects,
            sourceFraming: config.sourceFraming,
            framingHook: config.framingHook,
            effectManager: effectManager
        )

        guard case .success(let build) = buildResult else {
            if case .failure(let error) = buildResult {
                error.log(context: "RenderEngine.makePlayerItem")
                return .failure(error)
            }
            return .failure(.playerItemCreationFailed)
        }

        // Attach compositor to video composition
        build.videoComposition.customVideoCompositorClass = FrameCompositor.self

        // AVPlayerItem APIs are main-actor isolated in newer SDKs.
        let playerItem = await MainActor.run {
            let item = AVPlayerItem(asset: build.composition)
            item.videoComposition = build.videoComposition
            return item
        }

        return .success(playerItem)
    }

    @available(*, deprecated, renamed: "makePlayerItem(composition:config:effectManager:)")
    public func makePlayerItem(
        clip: Composition,
        config: Config,
        effectManager: EffectManager? = nil
    ) async -> Result<AVPlayerItem, RenderError> {
        await makePlayerItem(composition: clip, config: config, effectManager: effectManager)
    }
    
    // MARK: - Export

    /// Export to file
    public func export(
        composition: Composition,
        outputURL: URL,
        config: Config,
        hypnogramEffectChain: EffectChain? = nil
    ) async -> Result<URL, RenderError> {
        await exportComposition(
            composition: composition,
            outputURL: outputURL,
            config: config,
            hypnogramEffectChain: hypnogramEffectChain
        )
    }

    /// Compile a hypnogram into ordered sequence spans plus reusable composition build units.
    ///
    /// Sequence export uses a frame-aligned `SequenceRenderPlan`, then reuses the
    /// composition build path at those aligned durations so per-composition builds
    /// stay on the same frame grid as the enclosing sequence.
    public func makeSequenceBuild(
        hypnogram: Hypnogram,
        config: Config
    ) async -> Result<SequenceBuild, RenderError> {
        let exportHypnogram = hypnogram.copyForExport()
        guard !exportHypnogram.compositions.isEmpty else {
            return .failure(.noSources)
        }

        let plan = exportHypnogram.makeSequenceRenderPlan().alignedToFrameRate(config.frameRate)
        guard plan.totalDuration.seconds > 0 else {
            return .failure(.invalidDuration(plan.totalDuration))
        }

        let sequenceEffectManager = EffectManager()
        let frozenHypnogramEffectChain = exportHypnogram.effectChain.clone()
        sequenceEffectManager.hypnogramEffectChainProvider = { frozenHypnogramEffectChain }

        var compositionUnits: [CompositionBuildUnit] = []
        compositionUnits.reserveCapacity(exportHypnogram.compositions.count)

        for (index, composition) in exportHypnogram.compositions.enumerated() {
            let buildComposition = composition.copyForExport()
            let targetDurationOverride = plan.entries.first { $0.compositionIndex == index }?.compositionDuration
            let effectManager = EffectManager.forExport(
                composition: buildComposition,
                hypnogramEffectChain: nil
            )

            let buildResult = await compositionBuilder.build(
                composition: buildComposition,
                outputSize: config.outputSize,
                frameRate: config.frameRate,
                enableEffects: config.enableEffects,
                sourceFraming: config.sourceFraming,
                framingHook: config.framingHook,
                effectManager: effectManager,
                targetDurationOverride: targetDurationOverride
            )

            guard case .success(let build) = buildResult else {
                if case .failure(let error) = buildResult {
                    error.log(context: "RenderEngine.makeSequenceBuild[\(index)]")
                    return .failure(error)
                }
                return .failure(.compositionBuildFailed(
                    underlying: NSError(
                        domain: "RenderEngine",
                        code: 21,
                        userInfo: [NSLocalizedDescriptionKey: "Sequence composition build failed"]
                    )
                ))
            }

            build.videoComposition.customVideoCompositorClass = FrameCompositor.self
            guard let baseInstruction = build.instructions.first else {
                return .failure(.compositionBuildFailed(
                    underlying: NSError(
                        domain: "RenderEngine",
                        code: 22,
                        userInfo: [NSLocalizedDescriptionKey: "Missing base render instruction"]
                    )
                ))
            }

            let audioTrackCount = build.composition.tracks(withMediaType: .audio).count
            let audioTrackBaseVolume = audioTrackCount > 0 ? (1.0 / Float(audioTrackCount)) : 1.0

            compositionUnits.append(
                CompositionBuildUnit(
                    compositionIndex: index,
                    compositionID: buildComposition.id,
                    compositionDuration: buildComposition.effectiveDuration,
                    composition: build.composition,
                    videoComposition: build.videoComposition,
                    audioMix: build.audioMix,
                    layerTrackIDs: baseInstruction.layerTrackIDs,
                    blendModes: baseInstruction.blendModes,
                    transforms: baseInstruction.transforms,
                    sourceIndices: baseInstruction.sourceIndices,
                    stillImages: baseInstruction.stillImages,
                    sourceFraming: baseInstruction.sourceFraming,
                    framingHook: baseInstruction.framingHook,
                    renderID: baseInstruction.renderID,
                    effectManager: effectManager,
                    audioTrackBaseVolume: audioTrackBaseVolume
                )
            )
        }

        return .success(
            SequenceBuild(
                hypnogram: exportHypnogram,
                plan: plan,
                compositionUnits: compositionUnits,
                sequenceEffectManager: sequenceEffectManager
            )
        )
    }

    public func export(
        hypnogram: Hypnogram,
        outputURL: URL,
        config: Config
    ) async -> Result<URL, RenderError> {
        let sequenceBuildResult = await makeSequenceBuild(hypnogram: hypnogram, config: config)
        guard case .success(let sequenceBuild) = sequenceBuildResult else {
            if case .failure(let error) = sequenceBuildResult { return .failure(error) }
            return .failure(.compositionBuildFailed(
                underlying: NSError(
                    domain: "RenderEngine",
                    code: 23,
                    userInfo: [NSLocalizedDescriptionKey: "Failed to compile sequence build"]
                )
            ))
        }

        return await exportSequenceBuild(sequenceBuild, outputURL: outputURL, config: config)
    }

    private func exportComposition(
        composition: Composition,
        outputURL: URL,
        config: Config,
        hypnogramEffectChain: EffectChain?
    ) async -> Result<URL, RenderError> {

        print("🎬 RenderEngine.export: Starting export to \(outputURL.lastPathComponent)...")

        // Create an isolated copy of the composition with fresh effect state for export.
        // This prevents stateful effects (like TextOverlayEffect) from sharing state with preview
        let exportComposition = composition.copyForExport()
        let exportManager = EffectManager.forExport(
            composition: exportComposition,
            hypnogramEffectChain: hypnogramEffectChain?.clone()
        )

        // Build composition with the export manager
        let builder = CompositionBuilder()
        let buildResult = await builder.build(
            composition: exportComposition,
            outputSize: config.outputSize,
            frameRate: config.frameRate,
            enableEffects: config.enableEffects,
            sourceFraming: config.sourceFraming,
            framingHook: config.framingHook,
            effectManager: exportManager
        )

        guard case .success(let build) = buildResult else {
            if case .failure(let error) = buildResult {
                error.log(context: "RenderEngine.export")
                return .failure(error)
            }
            return .failure(.exportFailed(
                underlying: NSError(domain: "RenderEngine", code: 1,
                    userInfo: [NSLocalizedDescriptionKey: "Build failed"])
            ))
        }

        // Configure video composition with compositor BEFORE creating export session
        build.videoComposition.customVideoCompositorClass = FrameCompositor.self

        // For all-still compositions, export as PNG instead of video.
        let videoTracks = build.composition.tracks(withMediaType: .video)
        let hasActualVideoSegments = videoTracks.contains { track in
            track.segments.contains { !$0.isEmpty }
        }

        if !hasActualVideoSegments, let instruction = build.instructions.first {
            guard let montage = PhotoMontage(instruction: instruction, outputSize: config.outputSize) else {
                return .failure(.exportFailed(
                    underlying: NSError(domain: "RenderEngine", code: 10,
                        userInfo: [NSLocalizedDescriptionKey: "No images for photo montage"])))
            }

            print("🎬 All still images - exporting as PNG")
            switch montage.exportPNG(to: outputURL) {
            case .success(let url):
                print("✅ Export complete (PNG): \(url.lastPathComponent)")
                return .success(url)
            case .failure(let error):
                return .failure(.exportFailed(underlying: error))
            }
        }

        // Create export session
        guard let exportSession = AVAssetExportSession(
            asset: build.composition,
            presetName: AVAssetExportPresetHighestQuality
        ) else {
            return .failure(.exportFailed(
                underlying: NSError(domain: "RenderEngine", code: 2,
                    userInfo: [NSLocalizedDescriptionKey: "Failed to create export session"])
            ))
        }

        exportSession.outputURL = outputURL
        exportSession.outputFileType = .mov
        exportSession.videoComposition = build.videoComposition
        exportSession.audioMix = build.audioMix
        exportSession.shouldOptimizeForNetworkUse = false

        print("🎬 Exporting to \(outputURL.lastPathComponent)...")

        // Export with progress tracking
        await exportSession.export()

        switch exportSession.status {
        case .completed:
            print("✅ Export complete: \(outputURL.lastPathComponent)")
            return .success(outputURL)

        case .failed:
            let error = exportSession.error ?? NSError(domain: "RenderEngine", code: 3,
                userInfo: [NSLocalizedDescriptionKey: "Export failed with unknown error"])
            print("🔴 Export failed: \(error)")

            // Check if file was actually created despite the error
            if FileManager.default.fileExists(atPath: outputURL.path) {
                print("⚠️  File exists despite error - treating as success")
                return .success(outputURL)
            }

            return .failure(.exportFailed(underlying: error))

        case .cancelled:
            print("⚠️  Export cancelled")
            return .failure(.exportFailed(
                underlying: NSError(domain: "RenderEngine", code: 4,
                    userInfo: [NSLocalizedDescriptionKey: "Export cancelled"])
            ))

        default:
            print("🔴 Export unknown status: \(exportSession.status.rawValue)")
            return .failure(.exportFailed(
                underlying: NSError(domain: "RenderEngine", code: 5,
                    userInfo: [NSLocalizedDescriptionKey: "Export ended with unknown status"])
            ))
        }
    }

    private func exportSequenceBuild(
        _ sequenceBuild: SequenceBuild,
        outputURL: URL,
        config: Config
    ) async -> Result<URL, RenderError> {
        let fileManager = FileManager.default
        if fileManager.fileExists(atPath: outputURL.path) {
            do {
                try fileManager.removeItem(at: outputURL)
            } catch {
                return .failure(.exportFailed(underlying: error))
            }
        }

        let assemblyResult = assembleSequenceAsset(sequenceBuild, config: config)
        guard case .success(let assembly) = assemblyResult else {
            if case .failure(let error) = assemblyResult { return .failure(error) }
            return .failure(.exportFailed(
                underlying: NSError(
                    domain: "RenderEngine",
                    code: 24,
                    userInfo: [NSLocalizedDescriptionKey: "Failed to assemble sequence asset"]
                )
            ))
        }

        let validationResult = validateSequenceAssembly(
            assembly,
            expectedVideoDuration: sequenceBuild.plan.totalDuration
        )
        if case .failure(let error) = validationResult {
            return .failure(error)
        }

        guard let exportSession = AVAssetExportSession(
            asset: assembly.composition,
            presetName: AVAssetExportPresetHighestQuality
        ) else {
            return .failure(.exportFailed(
                underlying: NSError(
                    domain: "RenderEngine",
                    code: 25,
                    userInfo: [NSLocalizedDescriptionKey: "Failed to create sequence export session"]
                )
            ))
        }

        exportSession.outputURL = outputURL
        exportSession.outputFileType = .mov
        exportSession.videoComposition = assembly.videoComposition
        exportSession.audioMix = assembly.audioMix
        exportSession.shouldOptimizeForNetworkUse = false

        await exportSession.export()

        switch exportSession.status {
        case .completed:
            print("✅ Sequence export complete: \(outputURL.lastPathComponent)")
            return .success(outputURL)

        case .failed:
            let error = exportSession.error ?? NSError(
                domain: "RenderEngine",
                code: 26,
                userInfo: [NSLocalizedDescriptionKey: "Sequence export failed with unknown error"]
            )
            if let nsError = error as NSError? {
                print("🔴 Sequence export session failed: \(debugDescription(for: nsError))")
            }
            return .failure(.exportFailed(underlying: error))

        case .cancelled:
            return .failure(.exportFailed(
                underlying: NSError(
                    domain: "RenderEngine",
                    code: 27,
                    userInfo: [NSLocalizedDescriptionKey: "Sequence export cancelled"]
                )
            ))

        default:
            return .failure(.exportFailed(
                underlying: NSError(
                    domain: "RenderEngine",
                    code: 28,
                    userInfo: [NSLocalizedDescriptionKey: "Sequence export ended unexpectedly"]
                )
            ))
        }
    }

    private struct SequenceAssetAssembly {
        let composition: AVMutableComposition
        let videoComposition: AVMutableVideoComposition
        let audioMix: AVMutableAudioMix?
    }

    private struct ReusableCompositionTrack {
        let track: AVMutableCompositionTrack
        var availableAt: CMTime
    }

    private func assembleSequenceAsset(
        _ sequenceBuild: SequenceBuild,
        config: Config
    ) -> Result<SequenceAssetAssembly, RenderError> {
        let finalComposition = AVMutableComposition()
        let unitsByIndex = Dictionary(uniqueKeysWithValues: sequenceBuild.compositionUnits.map { ($0.compositionIndex, $0) })
        let entriesByIndex = Dictionary(uniqueKeysWithValues: sequenceBuild.plan.entries.map { ($0.compositionIndex, $0) })

        var passesByIndex: [Int: CompositionRenderPass] = [:]
        var audioParamsByIndex: [Int: [AVMutableAudioMixInputParameters]] = [:]
        var videoTrackPool: [ReusableCompositionTrack] = []

        do {
            for unit in sequenceBuild.compositionUnits {
                guard let entry = entriesByIndex[unit.compositionIndex] else { continue }

                let sourceVideoTracks = unit.composition.tracks(withMediaType: .video)
                let sourceAudioTracks = unit.composition.tracks(withMediaType: .audio)

                var remappedTrackIDs: [CMPersistentTrackID] = []
                remappedTrackIDs.reserveCapacity(unit.layerTrackIDs.count)

                for sourceTrackID in unit.layerTrackIDs {
                    guard let sourceTrack = sourceVideoTracks.first(where: { $0.trackID == sourceTrackID }) else {
                        return .failure(.noAssetTrack(name: "Missing source video track \(sourceTrackID)"))
                    }

                    let finalTrack = try allocateReusableTrack(
                        mediaType: .video,
                        in: finalComposition,
                        pool: &videoTrackPool,
                        startTime: entry.sequenceStartTime
                    )

                    if sourceTrack.segments.contains(where: { !$0.isEmpty }) {
                        try finalTrack.insertTimeRange(
                            CMTimeRange(start: .zero, duration: unit.compositionDuration),
                            of: sourceTrack,
                            at: entry.sequenceStartTime
                        )
                    } else {
                        finalTrack.insertEmptyTimeRange(
                            CMTimeRange(start: entry.sequenceStartTime, duration: unit.compositionDuration)
                        )
                    }

                    markReusableTrack(
                        trackID: finalTrack.trackID,
                        in: &videoTrackPool,
                        availableAt: CMTimeAdd(entry.sequenceStartTime, unit.compositionDuration)
                    )

                    remappedTrackIDs.append(finalTrack.trackID)
                }

                let pass = CompositionRenderPass(
                    timeRange: CMTimeRange(start: entry.sequenceStartTime, duration: unit.compositionDuration),
                    compositionTimeStart: .zero,
                    layerTrackIDs: remappedTrackIDs,
                    blendModes: unit.blendModes,
                    transforms: unit.transforms,
                    sourceIndices: unit.sourceIndices,
                    enableEffects: true,
                    stillImages: unit.stillImages,
                    sourceFraming: unit.sourceFraming,
                    framingHook: unit.framingHook,
                    renderID: unit.renderID,
                    effectManager: unit.effectManager,
                    applyHypnogramEffectsFromManager: false
                )
                passesByIndex[unit.compositionIndex] = pass

                var trackParams: [AVMutableAudioMixInputParameters] = []
                for sourceTrack in sourceAudioTracks {
                    guard let finalTrack = finalComposition.addMutableTrack(
                        withMediaType: .audio,
                        preferredTrackID: kCMPersistentTrackID_Invalid
                    ) else {
                        continue
                    }

                    try finalTrack.insertTimeRange(
                        CMTimeRange(start: .zero, duration: unit.compositionDuration),
                        of: sourceTrack,
                        at: entry.sequenceStartTime
                    )

                    let params = AVMutableAudioMixInputParameters(track: finalTrack)
                    params.setVolume(0, at: entry.sequenceStartTime)
                    trackParams.append(params)
                }
                audioParamsByIndex[unit.compositionIndex] = trackParams
            }
        } catch {
            return .failure(.exportFailed(underlying: error))
        }

        if finalComposition.duration.seconds <= 0, sequenceBuild.plan.totalDuration.seconds > 0 {
            finalComposition.insertEmptyTimeRange(
                CMTimeRange(start: .zero, duration: sequenceBuild.plan.totalDuration)
            )
        }

        let instructions = buildSequenceInstructions(
            plan: sequenceBuild.plan,
            passesByIndex: passesByIndex,
            sequenceEffectManager: sequenceBuild.sequenceEffectManager
        )

        let videoComposition = AVMutableVideoComposition()
        videoComposition.renderSize = sequenceBuild.compositionUnits.first?.videoComposition.renderSize ?? .zero
        videoComposition.frameDuration = CMTime(value: 1, timescale: CMTimeScale(max(1, config.frameRate)))
        videoComposition.instructions = instructions
        videoComposition.customVideoCompositorClass = FrameCompositor.self

        let audioMix = buildSequenceAudioMix(
            plan: sequenceBuild.plan,
            unitsByIndex: unitsByIndex,
            audioParamsByIndex: audioParamsByIndex
        )

        return .success(
            SequenceAssetAssembly(
                composition: finalComposition,
                videoComposition: videoComposition,
                audioMix: audioMix
            )
        )
    }

    private func allocateReusableTrack(
        mediaType: AVMediaType,
        in composition: AVMutableComposition,
        pool: inout [ReusableCompositionTrack],
        startTime: CMTime
    ) throws -> AVMutableCompositionTrack {
        let epsilon = 1.0 / 600.0

        if let reusableIndex = pool.firstIndex(where: { $0.availableAt.seconds <= startTime.seconds + epsilon }) {
            return pool[reusableIndex].track
        }

        guard let track = composition.addMutableTrack(
            withMediaType: mediaType,
            preferredTrackID: kCMPersistentTrackID_Invalid
        ) else {
            throw NSError(
                domain: "RenderEngine",
                code: 29,
                userInfo: [NSLocalizedDescriptionKey: "Failed to allocate final \(mediaType.rawValue) track"]
            )
        }

        pool.append(ReusableCompositionTrack(track: track, availableAt: .zero))
        return track
    }

    private func markReusableTrack(
        trackID: CMPersistentTrackID,
        in pool: inout [ReusableCompositionTrack],
        availableAt: CMTime
    ) {
        guard let index = pool.firstIndex(where: { $0.track.trackID == trackID }) else { return }
        pool[index].availableAt = availableAt
    }

    private func validateSequenceAssembly(
        _ assembly: SequenceAssetAssembly,
        expectedVideoDuration: CMTime
    ) -> Result<Void, RenderError> {
        let instructions = assembly.videoComposition.instructions
        guard !instructions.isEmpty else {
            return .failure(.compositionBuildFailed(
                underlying: NSError(
                    domain: "RenderEngine",
                    code: 35,
                    userInfo: [NSLocalizedDescriptionKey: "Sequence assembly produced no video instructions"]
                )
            ))
        }

        let compositionDuration = assembly.composition.duration
        let targetDuration = expectedVideoDuration.isValid && expectedVideoDuration.isNumeric
            ? expectedVideoDuration
            : compositionDuration
        let videoTracks = assembly.composition.tracks(withMediaType: .video)
        let videoTracksByID = Dictionary(uniqueKeysWithValues: videoTracks.map { ($0.trackID, $0) })
        let epsilon = 1.0 / 600.0

        var previousEndSeconds = 0.0

        for (index, instruction) in instructions.enumerated() {
            let timeRange = instruction.timeRange
            let startSeconds = timeRange.start.seconds
            let durationSeconds = timeRange.duration.seconds
            let endSeconds = CMTimeRangeGetEnd(timeRange).seconds

            guard durationSeconds.isFinite, durationSeconds > 0 else {
                return .failure(.compositionBuildFailed(
                    underlying: NSError(
                        domain: "RenderEngine",
                        code: 36,
                        userInfo: [
                            NSLocalizedDescriptionKey: "Instruction \(index) has invalid duration \(durationSeconds)s"
                        ]
                    )
                ))
            }

            if abs(startSeconds - previousEndSeconds) > epsilon {
                return .failure(.compositionBuildFailed(
                    underlying: NSError(
                        domain: "RenderEngine",
                        code: 37,
                        userInfo: [
                            NSLocalizedDescriptionKey: "Instruction \(index) is not contiguous",
                            "instructionStartSeconds": startSeconds,
                            "previousEndSeconds": previousEndSeconds
                        ]
                    )
                ))
            }

            let requiredTrackIDs = (instruction.requiredSourceTrackIDs ?? []).compactMap { value -> CMPersistentTrackID? in
                if let number = value as? NSNumber {
                    return CMPersistentTrackID(number.int32Value)
                }
                return nil
            }

            for trackID in requiredTrackIDs {
                guard let track = videoTracksByID[trackID] else {
                    return .failure(.compositionBuildFailed(
                        underlying: NSError(
                            domain: "RenderEngine",
                            code: 38,
                            userInfo: [
                                NSLocalizedDescriptionKey: "Instruction \(index) references missing video track \(trackID)"
                            ]
                        )
                    ))
                }

                let hasSegmentCoverage = track.segments.contains { segment in
                    guard !segment.isEmpty else { return false }
                    let targetRange = segment.timeMapping.target
                    return targetRange.duration.seconds > 0 &&
                        CMTimeRangeGetEnd(targetRange).seconds > startSeconds + epsilon &&
                        targetRange.start.seconds < endSeconds - epsilon
                }

                if !hasSegmentCoverage {
                    print("⚠️ Sequence assembly warning: instruction \(index) track \(trackID) has no non-empty segment coverage in \(startSeconds)s–\(endSeconds)s")
                }
            }

            previousEndSeconds = endSeconds
        }

        if abs(previousEndSeconds - targetDuration.seconds) > epsilon {
            return .failure(.compositionBuildFailed(
                underlying: NSError(
                    domain: "RenderEngine",
                    code: 39,
                    userInfo: [
                        NSLocalizedDescriptionKey: "Instruction coverage does not match composition duration",
                        "instructionsEndSeconds": previousEndSeconds,
                        "compositionDurationSeconds": compositionDuration.seconds,
                        "expectedVideoDurationSeconds": targetDuration.seconds
                    ]
                )
            ))
        }

        return .success(())
    }

    private func buildSequenceInstructions(
        plan: SequenceRenderPlan,
        passesByIndex: [Int: CompositionRenderPass],
        sequenceEffectManager: EffectManager
    ) -> [AVVideoCompositionInstructionProtocol] {
        plan.orderedSpans.compactMap { span -> AVVideoCompositionInstructionProtocol? in
            let timeRange: CMTimeRange
            let compositionIndices: [Int]
            let containsTweening: Bool

            switch span {
            case .compositionBody(let body):
                timeRange = CMTimeRange(
                    start: body.sequenceStartTime,
                    duration: CMTimeSubtract(body.sequenceEndTime, body.sequenceStartTime)
                )
                compositionIndices = [body.compositionIndex]
                containsTweening = false

            case .transition(let transition):
                timeRange = CMTimeRange(
                    start: transition.sequenceStartTime,
                    duration: CMTimeSubtract(transition.sequenceEndTime, transition.sequenceStartTime)
                )
                compositionIndices = [
                    transition.outgoingCompositionIndex,
                    transition.incomingCompositionIndex
                ]
                containsTweening = true
            }

            guard timeRange.duration.seconds > 0 else { return nil }

            let spanPairs: [(Int, CompositionRenderPass)] = compositionIndices.compactMap { index in
                guard let pass = passesByIndex[index] else { return nil }
                return (index, pass)
            }
            let spanPasses = Dictionary(uniqueKeysWithValues: spanPairs)

            guard !spanPasses.isEmpty else { return nil }

            return SequenceRenderInstruction(
                timeRange: timeRange,
                containsTweening: containsTweening,
                plan: plan,
                passesByIndex: spanPasses,
                sequenceEffectManager: sequenceEffectManager
            )
        }
    }

    private func buildSequenceAudioMix(
        plan: SequenceRenderPlan,
        unitsByIndex: [Int: CompositionBuildUnit],
        audioParamsByIndex: [Int: [AVMutableAudioMixInputParameters]]
    ) -> AVMutableAudioMix? {
        let transitionsByOutgoing = Dictionary(uniqueKeysWithValues: plan.transitions.map { ($0.outgoingCompositionIndex, $0) })
        let transitionsByIncoming = Dictionary(uniqueKeysWithValues: plan.transitions.map { ($0.incomingCompositionIndex, $0) })

        var allParams: [AVMutableAudioMixInputParameters] = []

        for entry in plan.entries {
            guard let params = audioParamsByIndex[entry.compositionIndex],
                  let unit = unitsByIndex[entry.compositionIndex] else {
                continue
            }

            let baseVolume = unit.audioTrackBaseVolume
            let incomingTransition = transitionsByIncoming[entry.compositionIndex]
            let outgoingTransition = transitionsByOutgoing[entry.compositionIndex]
            let timing = resolvedAudioTransitionTiming(
                for: entry,
                incomingTransition: incomingTransition,
                outgoingTransition: outgoingTransition
            )

            for param in params {
                if let incomingTransition {
                    applyIncomingAudioTransition(
                        style: incomingTransition.style,
                        duration: timing.incomingDuration,
                        startTime: timing.incomingStartTime,
                        baseVolume: baseVolume,
                        params: param
                    )
                } else {
                    param.setVolume(baseVolume, at: entry.sequenceStartTime)
                }

                if let outgoingTransition {
                    applyOutgoingAudioTransition(
                        style: outgoingTransition.style,
                        duration: timing.outgoingDuration,
                        startTime: timing.outgoingStartTime,
                        baseVolume: baseVolume,
                        params: param
                    )
                }

                allParams.append(param)
            }
        }

        guard !allParams.isEmpty else { return nil }
        let mix = AVMutableAudioMix()
        mix.inputParameters = allParams
        return mix
    }

    private struct AudioTransitionTiming {
        let incomingStartTime: CMTime
        let incomingDuration: CMTime
        let outgoingStartTime: CMTime
        let outgoingDuration: CMTime
    }

    private func resolvedAudioTransitionTiming(
        for entry: SequenceRenderPlan.CompositionEntry,
        incomingTransition: SequenceRenderPlan.BoundaryTransition?,
        outgoingTransition: SequenceRenderPlan.BoundaryTransition?
    ) -> AudioTransitionTiming {
        let compositionDurationSeconds = max(0, entry.compositionDuration.seconds)
        let incomingDurationSeconds = max(0, incomingTransition?.duration.seconds ?? 0)
        let outgoingDurationSeconds = max(0, outgoingTransition?.duration.seconds ?? 0)

        var resolvedIncomingDurationSeconds = incomingDurationSeconds
        var resolvedOutgoingDurationSeconds = outgoingDurationSeconds

        let totalTransitionSeconds = incomingDurationSeconds + outgoingDurationSeconds
        if compositionDurationSeconds > 0, totalTransitionSeconds > compositionDurationSeconds {
            let scale = compositionDurationSeconds / totalTransitionSeconds
            resolvedIncomingDurationSeconds *= scale
            resolvedOutgoingDurationSeconds *= scale
        }

        let incomingStartTime = incomingTransition?.sequenceStartTime ?? entry.sequenceStartTime
        let outgoingStartTime = CMTimeSubtract(
            outgoingTransition?.sequenceEndTime ?? entry.sequenceEndTime,
            Self.time(seconds: resolvedOutgoingDurationSeconds)
        )

        return AudioTransitionTiming(
            incomingStartTime: incomingStartTime,
            incomingDuration: Self.time(seconds: resolvedIncomingDurationSeconds),
            outgoingStartTime: outgoingStartTime,
            outgoingDuration: Self.time(seconds: resolvedOutgoingDurationSeconds)
        )
    }

    private func applyIncomingAudioTransition(
        style: TransitionRenderer.TransitionType,
        duration: CMTime,
        startTime: CMTime,
        baseVolume: Float,
        params: AVMutableAudioMixInputParameters
    ) {
        switch style {
        case .fadeToBlack:
            let halfDuration = CMTimeMultiplyByFloat64(duration, multiplier: 0.5)
            let secondHalfStart = CMTimeAdd(startTime, halfDuration)
            params.setVolume(0, at: startTime)
            params.setVolumeRamp(
                fromStartVolume: 0,
                toEndVolume: baseVolume,
                timeRange: CMTimeRange(start: secondHalfStart, duration: CMTimeSubtract(duration, halfDuration))
            )

        case .crossfade, .blur, .slideUp, .slideLeft:
            params.setVolumeRamp(
                fromStartVolume: 0,
                toEndVolume: baseVolume,
                timeRange: CMTimeRange(start: startTime, duration: duration)
            )

        case .none:
            params.setVolume(baseVolume, at: startTime)
        }
    }

    private func applyOutgoingAudioTransition(
        style: TransitionRenderer.TransitionType,
        duration: CMTime,
        startTime: CMTime,
        baseVolume: Float,
        params: AVMutableAudioMixInputParameters
    ) {
        switch style {
        case .fadeToBlack:
            let halfDuration = CMTimeMultiplyByFloat64(duration, multiplier: 0.5)
            params.setVolumeRamp(
                fromStartVolume: baseVolume,
                toEndVolume: 0,
                timeRange: CMTimeRange(start: startTime, duration: halfDuration)
            )
            params.setVolume(0, at: CMTimeAdd(startTime, halfDuration))

        case .crossfade, .blur, .slideUp, .slideLeft:
            params.setVolumeRamp(
                fromStartVolume: baseVolume,
                toEndVolume: 0,
                timeRange: CMTimeRange(start: startTime, duration: duration)
            )

        case .none:
            params.setVolume(0, at: startTime)
        }
    }

    private static func time(seconds: Double) -> CMTime {
        CMTime(seconds: seconds, preferredTimescale: 600)
    }

    private func debugDescription(for error: NSError) -> String {
        var parts: [String] = ["\(error.domain) \(error.code): \(error.localizedDescription)"]
        if let failureReason = error.localizedFailureReason {
            parts.append("reason=\(failureReason)")
        }
        if let recovery = error.localizedRecoverySuggestion {
            parts.append("suggestion=\(recovery)")
        }
        if let underlying = error.userInfo[NSUnderlyingErrorKey] as? NSError {
            parts.append("underlying=[\(debugDescription(for: underlying))]")
        }
        if let stack = error.userInfo["NSMultipleUnderlyingErrorsKey"] as? [NSError], !stack.isEmpty {
            let rendered = stack.map { debugDescription(for: $0) }.joined(separator: "; ")
            parts.append("multiple=[\(rendered)]")
        }
        return parts.joined(separator: " | ")
    }

    @available(*, deprecated, renamed: "export(composition:outputURL:config:)")
    public func export(
        clip: Composition,
        outputURL: URL,
        config: Config
    ) async -> Result<URL, RenderError> {
        await export(composition: clip, outputURL: outputURL, config: config)
    }

    // MARK: - Export Queue

    public final class ExportQueue {
        public private(set) var activeJobs: Int = 0
        public var onAllJobsFinished: (() -> Void)?
        public var onStatusMessage: ((String) -> Void)?

        public init() {}

        public func enqueue(
            composition: Composition,
            outputFolder: URL,
            outputSize: CGSize,
            frameRate: Int = 30,
            enableEffects: Bool = true,
            sourceFraming: SourceFraming = .fill,
            hypnogramEffectChain: EffectChain? = nil,
            notifyExternalDestinationHooks: Bool = true,
            completion: ((Result<URL, RenderError>) -> Void)? = nil
        ) {
            activeJobs += 1
            onStatusMessage?("Rendering started")

            Task {
                let result: Result<URL, RenderError> = await {
                    let preparedOutput: Result<URL, RenderError> = Self.prepareOutputURL(
                        in: outputFolder,
                        prefix: "hypnograph"
                    )
                    guard case .success(let outputURL) = preparedOutput else {
                        if case .failure(let error) = preparedOutput { return .failure(error) }
                        return .failure(.exportFailed(underlying: NSError(domain: "RenderEngine", code: 33)))
                    }

                    let config = RenderEngine.Config(
                        outputSize: outputSize,
                        frameRate: frameRate,
                        enableEffects: enableEffects,
                        sourceFraming: sourceFraming
                    )

                    let engine = RenderEngine()
                    return await engine.export(
                        composition: composition,
                        outputURL: outputURL,
                        config: config,
                        hypnogramEffectChain: hypnogramEffectChain
                    )
                }()

                await MainActor.run {
                    self.activeJobs -= 1

                    switch result {
                    case .success(let url):
                        print("Render job finished: \(url.path)")
                        self.onStatusMessage?("Saved: \(url.lastPathComponent)")

                        // Notify via hook for external destinations (e.g., Apple Photos)
                        if notifyExternalDestinationHooks,
                           let hook = HypnoCoreHooks.shared.onVideoExportCompleted {
                            Task {
                                await hook(url)
                            }
                        }

                    case .failure(let error):
                        print("Render job failed: \(error.localizedDescription)")
                        self.onStatusMessage?("Save failed: \(error.localizedDescription)")
                    }

                    completion?(result)

                    if self.activeJobs == 0 {
                        self.onAllJobsFinished?()
                    }
                }
            }
        }

        public func enqueue(
            hypnogram: Hypnogram,
            outputFolder: URL,
            outputSize: CGSize,
            frameRate: Int = 30,
            enableEffects: Bool = true,
            sourceFraming: SourceFraming = .fill,
            notifyExternalDestinationHooks: Bool = true,
            completion: ((Result<URL, RenderError>) -> Void)? = nil
        ) {
            activeJobs += 1
            onStatusMessage?("Sequence render started")

            Task {
                let result: Result<URL, RenderError> = await {
                    let preparedOutput: Result<URL, RenderError> = Self.prepareOutputURL(
                        in: outputFolder,
                        prefix: "hypnograph-sequence"
                    )
                    guard case .success(let outputURL) = preparedOutput else {
                        if case .failure(let error) = preparedOutput { return .failure(error) }
                        return .failure(.exportFailed(underlying: NSError(domain: "RenderEngine", code: 34)))
                    }

                    let config = RenderEngine.Config(
                        outputSize: outputSize,
                        frameRate: frameRate,
                        enableEffects: enableEffects,
                        sourceFraming: sourceFraming
                    )

                    let engine = RenderEngine()
                    return await engine.export(
                        hypnogram: hypnogram,
                        outputURL: outputURL,
                        config: config
                    )
                }()

                await MainActor.run {
                    self.activeJobs -= 1

                    switch result {
                    case .success(let url):
                        print("Sequence render job finished: \(url.path)")
                        self.onStatusMessage?("Saved: \(url.lastPathComponent)")

                        if notifyExternalDestinationHooks,
                           let hook = HypnoCoreHooks.shared.onVideoExportCompleted {
                            Task {
                                await hook(url)
                            }
                        }

                    case .failure(let error):
                        error.log(context: "RenderEngine.ExportQueue.sequence")
                        print("Sequence render job failed: \(error.description)")
                        self.onStatusMessage?("Save failed: \(error.description)")
                    }

                    completion?(result)

                    if self.activeJobs == 0 {
                        self.onAllJobsFinished?()
                    }
                }
            }
        }

        private static func prepareOutputURL(
            in outputFolder: URL,
            prefix: String
        ) -> Result<URL, RenderError> {
            let fm = FileManager.default

            if !outputFolder.isFileURL {
                return .failure(.exportFailed(
                    underlying: NSError(
                        domain: "RenderEngine",
                        code: 11,
                        userInfo: [NSLocalizedDescriptionKey: "Output folder is not a file URL"]
                    )
                ))
            }

            do {
                try fm.createDirectory(at: outputFolder, withIntermediateDirectories: true)
            } catch {
                return .failure(.exportFailed(
                    underlying: NSError(
                        domain: "RenderEngine",
                        code: 12,
                        userInfo: [
                            NSLocalizedDescriptionKey: "Failed to create output directory",
                            NSUnderlyingErrorKey: error
                        ]
                    )
                ))
            }

            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            let timestamp = formatter.string(from: Date())
                .replacingOccurrences(of: ":", with: "-")
            let filename = "\(prefix)-\(timestamp).mov"
            let outputURL = outputFolder.appendingPathComponent(filename)

            if fm.fileExists(atPath: outputURL.path) {
                do {
                    try fm.removeItem(at: outputURL)
                } catch {
                    return .failure(.exportFailed(
                        underlying: NSError(
                            domain: "RenderEngine",
                            code: 13,
                            userInfo: [
                                NSLocalizedDescriptionKey: "Failed to remove existing output file",
                                NSUnderlyingErrorKey: error
                            ]
                        )
                    ))
                }
            }

            return .success(outputURL)
        }

        @available(*, deprecated, renamed: "enqueue(composition:outputFolder:outputSize:frameRate:enableEffects:sourceFraming:notifyExternalDestinationHooks:completion:)")
        public func enqueue(
            clip: Composition,
            outputFolder: URL,
            outputSize: CGSize,
            frameRate: Int = 30,
            enableEffects: Bool = true,
            sourceFraming: SourceFraming = .fill,
            hypnogramEffectChain: EffectChain? = nil,
            notifyExternalDestinationHooks: Bool = true,
            completion: ((Result<URL, RenderError>) -> Void)? = nil
        ) {
            enqueue(
                composition: clip,
                outputFolder: outputFolder,
                outputSize: outputSize,
                frameRate: frameRate,
                enableEffects: enableEffects,
                sourceFraming: sourceFraming,
                hypnogramEffectChain: hypnogramEffectChain,
                notifyExternalDestinationHooks: notifyExternalDestinationHooks,
                completion: completion
            )
        }
    }
}
