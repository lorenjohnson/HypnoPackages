//
//  CompositionBuilder.swift
//  Hypnograph
//
//  Builds AVComposition + instructions from recipe
//

import Foundation
import AVFoundation
import CoreGraphics
import CoreImage

/// Builds compositions for preview and export
final class CompositionBuilder {
    
    // MARK: - Types
    
    struct BuildResult {
        let composition: AVMutableComposition
        let videoComposition: AVMutableVideoComposition
        let audioMix: AVMutableAudioMix?  // for mixing multiple audio tracks
        let instructions: [RenderInstruction]
        let clipStartTimes: [CMTime]  // for sequence seeking
    }
    
    enum TimelineStrategy {
        case montage(targetDuration: CMTime)
        case sequence  // concatenate clips
    }
    
    // MARK: - Dependencies
    
    private let sourceLoader = SourceLoader()
    
    // MARK: - Build

    /// Build a composition from a recipe
    /// - Parameters:
    ///   - recipe: The recipe to build
    ///   - strategy: Montage or sequence timeline
    ///   - outputSize: Output dimensions
    ///   - frameRate: Output frame rate
    ///   - enableEffects: Whether to apply effects
    ///   - effectManager: The EffectManager to use for this composition.
    ///                  Pass nil only for legacy callers; all new code should provide a manager.
    func build(
        recipe: HypnogramRecipe,
        strategy: TimelineStrategy,
        outputSize: CGSize,
        frameRate: Int = 30,
        enableEffects: Bool = true,
        effectManager: EffectManager? = nil
    ) async -> Result<BuildResult, RenderError> {

        // Validate
        guard !recipe.sources.isEmpty else {
            return .failure(.noSources)
        }

        guard outputSize.width > 0 && outputSize.height > 0 else {
            return .failure(.invalidOutputSize(outputSize))
        }

        // Build based on strategy
        switch strategy {
        case .montage(let targetDuration):
            return await buildMontage(
                recipe: recipe,
                targetDuration: targetDuration,
                outputSize: outputSize,
                frameRate: frameRate,
                enableEffects: enableEffects,
                effectManager: effectManager
            )
        case .sequence:
            return await buildSequence(
                recipe: recipe,
                outputSize: outputSize,
                frameRate: frameRate,
                enableEffects: enableEffects,
                effectManager: effectManager
            )
        }
    }

    // MARK: - Montage Builder

    private func buildMontage(
        recipe: HypnogramRecipe,
        targetDuration: CMTime,
        outputSize: CGSize,
        frameRate: Int,
        enableEffects: Bool,
        effectManager: EffectManager?
    ) async -> Result<BuildResult, RenderError> {

        // Load all sources
        var loadedSources: [(source: HypnogramSource, loaded: LoadedSource)] = []

        for (index, source) in recipe.sources.enumerated() {
            let result = await sourceLoader.load(source: source)

            switch result {
            case .success(let loaded):
                loadedSources.append((source, loaded))
            case .failure(let error):
                error.log(context: "CompositionBuilder.montage[\(index)]")
                // Skip failed sources for now (in Phase 3 we'll replace with fallback)
                continue
            }
        }

        guard !loadedSources.isEmpty else {
            return .failure(.allSourcesFailedToLoad)
        }

        // Loaded logging removed to reduce noise

        // Create composition
        let composition = AVMutableComposition()
        var trackIDs: [CMPersistentTrackID] = []
        var audioTrackIDs: [CMPersistentTrackID] = []
        var transforms: [CGAffineTransform] = []
        var blendModes: [String] = []
        var sourceIndices: [Int] = []
        var stillImages: [CIImage?] = []

        for (index, (source, loaded)) in loadedSources.enumerated() {
            guard let track = composition.addMutableTrack(
                withMediaType: .video,
                preferredTrackID: kCMPersistentTrackID_Invalid
            ) else {
                print("🔴 Failed to create track \(index)")
                continue
            }

            if loaded.isStillImage {
                // For still images: insert empty time range so track has valid segments.
                // AVAssetExportSession fails if tracks have no segments at all.
                track.insertEmptyTimeRange(CMTimeRange(start: .zero, duration: targetDuration))
                stillImages.append(loaded.ciImage)
            } else {
                // For videos: insert media, looping if needed
                guard let videoTrack = loaded.videoTrack else {
                    print("🔴 Video source \(index) has no video track")
                    continue
                }

                let clipDuration = source.clip.duration
                var currentTime = CMTime.zero
                var loopCount = 0

                while currentTime < targetDuration {
                    let remainingDuration = CMTimeSubtract(targetDuration, currentTime)
                    let insertDuration = CMTimeMinimum(clipDuration, remainingDuration)
                    let insertRange = CMTimeRange(start: source.clip.startTime, duration: insertDuration)

                    do {
                        try track.insertTimeRange(insertRange, of: videoTrack, at: currentTime)
                        currentTime = CMTimeAdd(currentTime, insertDuration)
                        loopCount += 1
                    } catch {
                        print("🔴 Failed to insert source \(index) loop \(loopCount): \(error)")
                        break
                    }
                }

                stillImages.append(nil as CIImage?)

                // Add audio track if available (mirror video looping)
                if let audioTrack = loaded.audioTrack {
                    guard let compAudioTrack = composition.addMutableTrack(
                        withMediaType: .audio,
                        preferredTrackID: kCMPersistentTrackID_Invalid
                    ) else {
                        print("⚠️  Failed to create audio track for source \(index)")
                        continue
                    }

                    var audioTime = CMTime.zero
                    var audioLoopCount = 0

                    while audioTime < targetDuration {
                        let remainingDuration = CMTimeSubtract(targetDuration, audioTime)
                        let insertDuration = CMTimeMinimum(clipDuration, remainingDuration)
                        let insertRange = CMTimeRange(start: source.clip.startTime, duration: insertDuration)

                        do {
                            try compAudioTrack.insertTimeRange(insertRange, of: audioTrack, at: audioTime)
                            audioTime = CMTimeAdd(audioTime, insertDuration)
                            audioLoopCount += 1
                        } catch {
                            print("🔴 Failed to insert audio for source \(index) loop \(audioLoopCount): \(error)")
                            break
                        }
                    }
                    audioTrackIDs.append(compAudioTrack.trackID)
                }
            }

            trackIDs.append(track.trackID)
            // Compose metadata transform with user transforms array
            let userTransform = source.transforms.reduce(CGAffineTransform.identity) { $0.concatenating($1) }
            let composedTransform = loaded.transform.concatenating(userTransform)
            transforms.append(composedTransform)
            sourceIndices.append(index)

            // Get blend mode from source (default to SourceOver for first, Screen for others)
            let blendMode = source.blendMode ?? (index == 0 ? BlendMode.sourceOver : BlendMode.defaultMontage)
            blendModes.append(blendMode)
        }

        guard !trackIDs.isEmpty else {
            return .failure(.allSourcesFailedToLoad)
        }

        // If we have still images, we need to ensure composition has duration
        // (empty tracks don't extend composition duration)
        if composition.duration.seconds <= 0 {
            composition.insertEmptyTimeRange(CMTimeRange(start: .zero, duration: targetDuration))
        }

        // Create instruction with effect manager for effect processing
        let instruction = RenderInstruction(
            timeRange: CMTimeRange(start: .zero, duration: targetDuration),
            layerTrackIDs: trackIDs,
            blendModes: blendModes,
            transforms: transforms,
            sourceIndices: sourceIndices,
            enableEffects: enableEffects,
            stillImages: stillImages,
            effectManager: effectManager
        )

        // Create video composition
        let videoComposition = AVMutableVideoComposition()
        videoComposition.frameDuration = CMTime(value: 1, timescale: CMTimeScale(frameRate))
        videoComposition.renderSize = outputSize
        videoComposition.instructions = [instruction]

        // Create audio mix for multiple audio tracks (normalizes volume across tracks)
        var audioMix: AVMutableAudioMix? = nil
        if !audioTrackIDs.isEmpty {
            audioMix = AVMutableAudioMix()
            let inputParameters = audioTrackIDs.map { trackID -> AVMutableAudioMixInputParameters in
                let params = AVMutableAudioMixInputParameters(track: nil)
                params.trackID = trackID
                // Reduce volume per track to prevent clipping when mixing
                let volumePerTrack = 1.0 / Float(audioTrackIDs.count)
                params.setVolume(volumePerTrack, at: .zero)
                return params
            }
            audioMix?.inputParameters = inputParameters
        }

        let result = BuildResult(
            composition: composition,
            videoComposition: videoComposition,
            audioMix: audioMix,
            instructions: [instruction],
            clipStartTimes: [.zero]
        )

        // Success logging removed to reduce noise
        return .success(result)
    }

    // MARK: - Sequence Builder

    private func buildSequence(
        recipe: HypnogramRecipe,
        outputSize: CGSize,
        frameRate: Int,
        enableEffects: Bool,
        effectManager: EffectManager?
    ) async -> Result<BuildResult, RenderError> {

        // Load all sources (track original index for correct seeking)
        var loadedSources: [(source: HypnogramSource, loaded: LoadedSource, originalIndex: Int)] = []

        for (index, source) in recipe.sources.enumerated() {
            let result = await sourceLoader.load(source: source)

            switch result {
            case .success(let loaded):
                loadedSources.append((source, loaded, index))
            case .failure(let error):
                error.log(context: "CompositionBuilder.sequence[\(index)]")
                continue
            }
        }

        guard !loadedSources.isEmpty else {
            return .failure(.allSourcesFailedToLoad)
        }

        // Loaded logging removed to reduce noise

        // Create composition with video and audio tracks
        let composition = AVMutableComposition()

        guard let videoTrack = composition.addMutableTrack(
            withMediaType: .video,
            preferredTrackID: kCMPersistentTrackID_Invalid
        ) else {
            return .failure(.compositionBuildFailed(
                underlying: NSError(domain: "CompositionBuilder", code: 2,
                    userInfo: [NSLocalizedDescriptionKey: "Failed to create video track"])
            ))
        }

        guard let audioTrack = composition.addMutableTrack(
            withMediaType: .audio,
            preferredTrackID: kCMPersistentTrackID_Invalid
        ) else {
            return .failure(.compositionBuildFailed(
                underlying: NSError(domain: "CompositionBuilder", code: 3,
                    userInfo: [NSLocalizedDescriptionKey: "Failed to create audio track"])
            ))
        }

        // Insert clips sequentially
        var currentTime = CMTime.zero
        var clipStartTimes: [CMTime] = []
        var instructions: [RenderInstruction] = []

        for (source, loaded, originalIndex) in loadedSources {
            let clipDuration = source.clip.duration

            clipStartTimes.append(currentTime)

            // Compose metadata transform with user transforms array
            let userTransform = source.transforms.reduce(CGAffineTransform.identity) { $0.concatenating($1) }
            let composedTransform = loaded.transform.concatenating(userTransform)

            if loaded.isStillImage {
                // For still images: insert empty time range into the video track, store CIImage in instruction
                videoTrack.insertEmptyTimeRange(CMTimeRange(start: currentTime, duration: clipDuration))

                let instruction = RenderInstruction(
                    timeRange: CMTimeRange(start: currentTime, duration: clipDuration),
                    layerTrackIDs: [videoTrack.trackID],
                    blendModes: [BlendMode.sourceOver],
                    transforms: [composedTransform],
                    sourceIndices: [originalIndex],
                    enableEffects: enableEffects,
                    stillImages: [loaded.ciImage],
                    effectManager: effectManager
                )
                instructions.append(instruction)
            } else {
                // For videos: insert media
                guard let srcVideoTrack = loaded.videoTrack else {
                    print("🔴 Video source \(originalIndex) has no video track")
                    continue
                }

                let sourceRange = CMTimeRange(start: source.clip.startTime, duration: clipDuration)

                do {
                    try videoTrack.insertTimeRange(sourceRange, of: srcVideoTrack, at: currentTime)
                } catch {
                    print("🔴 Failed to insert clip \(originalIndex): \(error)")
                    continue
                }

                // Insert audio if available
                if let srcAudioTrack = loaded.audioTrack {
                    do {
                        try audioTrack.insertTimeRange(sourceRange, of: srcAudioTrack, at: currentTime)
                    } catch {
                        print("⚠️  Failed to insert audio for clip \(originalIndex): \(error)")
                    }
                }

                let instruction = RenderInstruction(
                    timeRange: CMTimeRange(start: currentTime, duration: clipDuration),
                    layerTrackIDs: [videoTrack.trackID],
                    blendModes: [BlendMode.sourceOver],
                    transforms: [composedTransform],
                    sourceIndices: [originalIndex],
                    enableEffects: enableEffects,
                    stillImages: [nil],
                    effectManager: effectManager
                )
                instructions.append(instruction)
            }

            currentTime = CMTimeAdd(currentTime, clipDuration)
        }

        guard !instructions.isEmpty else {
            return .failure(.allSourcesFailedToLoad)
        }

        // Create video composition
        let videoComposition = AVMutableVideoComposition()
        videoComposition.frameDuration = CMTime(value: 1, timescale: CMTimeScale(frameRate))
        videoComposition.renderSize = outputSize
        videoComposition.instructions = instructions

        let result = BuildResult(
            composition: composition,
            videoComposition: videoComposition,
            audioMix: nil,  // Sequence uses single audio track, no mixing needed
            instructions: instructions,
            clipStartTimes: clipStartTimes
        )

        // Success logging removed to reduce noise
        return .success(result)
    }

    // MARK: - Single Source Builder

    func buildSingleSource(
        source: HypnogramSource,
        sourceIndex: Int,
        outputSize: CGSize,
        frameRate: Int = 30,
        enableEffects: Bool = true,
        effectManager: EffectManager? = nil
    ) async -> Result<BuildResult, RenderError> {
        let result = await sourceLoader.load(source: source)

        guard case .success(let loaded) = result else {
            if case .failure(let error) = result {
                error.log(context: "CompositionBuilder.singleSource[\(sourceIndex)]")
                return .failure(error)
            }
            return .failure(.allSourcesFailedToLoad)
        }

        let composition = AVMutableComposition()
        guard let videoTrack = composition.addMutableTrack(
            withMediaType: .video,
            preferredTrackID: kCMPersistentTrackID_Invalid
        ) else {
            return .failure(.compositionBuildFailed(
                underlying: NSError(domain: "CompositionBuilder", code: 4,
                    userInfo: [NSLocalizedDescriptionKey: "Failed to create video track"])
            ))
        }

        var instructions: [RenderInstruction] = []
        let clipDuration = source.clip.duration

        // Compose metadata transform with user transforms array
        let userTransform = source.transforms.reduce(CGAffineTransform.identity) { $0.concatenating($1) }
        let composedTransform = loaded.transform.concatenating(userTransform)

        if loaded.isStillImage {
            videoTrack.insertEmptyTimeRange(CMTimeRange(start: .zero, duration: clipDuration))

            let instruction = RenderInstruction(
                timeRange: CMTimeRange(start: .zero, duration: clipDuration),
                layerTrackIDs: [videoTrack.trackID],
                blendModes: [BlendMode.sourceOver],
                transforms: [composedTransform],
                sourceIndices: [sourceIndex],
                enableEffects: enableEffects,
                stillImages: [loaded.ciImage],
                effectManager: effectManager
            )
            instructions = [instruction]
        } else {
            guard let srcVideoTrack = loaded.videoTrack else {
                return .failure(.noVideoTrack(name: source.clip.file.displayName))
            }

            let sourceRange = CMTimeRange(start: source.clip.startTime, duration: clipDuration)
            do {
                try videoTrack.insertTimeRange(sourceRange, of: srcVideoTrack, at: .zero)
            } catch {
                return .failure(.compositionBuildFailed(underlying: error))
            }

            if let srcAudioTrack = loaded.audioTrack {
                if let audioTrack = composition.addMutableTrack(
                    withMediaType: .audio,
                    preferredTrackID: kCMPersistentTrackID_Invalid
                ) {
                    do {
                        try audioTrack.insertTimeRange(sourceRange, of: srcAudioTrack, at: .zero)
                    } catch {
                        print("⚠️  Failed to insert audio for clip \(sourceIndex): \(error)")
                    }
                }
            }

            let instruction = RenderInstruction(
                timeRange: CMTimeRange(start: .zero, duration: clipDuration),
                layerTrackIDs: [videoTrack.trackID],
                blendModes: [BlendMode.sourceOver],
                transforms: [composedTransform],
                sourceIndices: [sourceIndex],
                enableEffects: enableEffects,
                stillImages: [nil],
                effectManager: effectManager
            )
            instructions = [instruction]
        }

        let videoComposition = AVMutableVideoComposition()
        videoComposition.frameDuration = CMTime(value: 1, timescale: CMTimeScale(frameRate))
        videoComposition.renderSize = outputSize
        videoComposition.instructions = instructions

        let build = BuildResult(
            composition: composition,
            videoComposition: videoComposition,
            audioMix: nil,
            instructions: instructions,
            clipStartTimes: [.zero]
        )

        return .success(build)
    }
}
