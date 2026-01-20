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
    }
    
    // MARK: - Dependencies
    
    private let sourceLoader = SourceLoader()
    
    // MARK: - Build

    /// Build a montage composition from a clip.
    /// - Parameters:
    ///   - clip: The clip to build
    ///   - outputSize: Output dimensions
    ///   - frameRate: Output frame rate
    ///   - enableEffects: Whether to apply effects
    ///   - effectManager: The EffectManager to use for this composition.
    ///                  Pass nil only for legacy callers; all new code should provide a manager.
    func build(
        clip: HypnogramClip,
        outputSize: CGSize,
        frameRate: Int = 30,
        enableEffects: Bool = true,
        sourceFraming: SourceFraming = .fill,
        effectManager: EffectManager? = nil
    ) async -> Result<BuildResult, RenderError> {

        // Validate
        guard !clip.sources.isEmpty else {
            return .failure(.noSources)
        }

        guard outputSize.width > 0 && outputSize.height > 0 else {
            return .failure(.invalidOutputSize(outputSize))
        }

        return await buildMontage(
            clip: clip,
            targetDuration: clip.targetDuration,
            outputSize: outputSize,
            frameRate: frameRate,
            enableEffects: enableEffects,
            sourceFraming: sourceFraming,
            effectManager: effectManager
        )
    }

    // MARK: - Montage Builder

    private func buildMontage(
        clip: HypnogramClip,
        targetDuration: CMTime,
        outputSize: CGSize,
        frameRate: Int,
        enableEffects: Bool,
        sourceFraming: SourceFraming,
        effectManager: EffectManager?
    ) async -> Result<BuildResult, RenderError> {

        // Load all sources
        var loadedSources: [(source: HypnogramSource, loaded: LoadedSource)] = []

        for (index, source) in clip.sources.enumerated() {
            let result = await sourceLoader.load(source: source)

            switch result {
            case .success(let loaded):
                loadedSources.append((source, loaded))
            case .failure(let error):
                error.log(context: "CompositionBuilder.montage[\(index)]")
                // Skip failed sources for now (we can replace with fallback later if needed)
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
        var layerPersonBounds: [CGRect?] = []

        for (index, (source, loaded)) in loadedSources.enumerated() {
            guard let track = composition.addMutableTrack(
                withMediaType: .video,
                preferredTrackID: kCMPersistentTrackID_Invalid
            ) else {
                print("🔴 Failed to create track \(index)")
                continue
            }

            // Compose metadata transform with user transforms array
            let userTransform = source.transforms.reduce(CGAffineTransform.identity) { $0.concatenating($1) }
            let composedTransform = loaded.transform.concatenating(userTransform)

            if loaded.isStillImage {
                // For still images: insert empty time range so track has valid segments.
                // AVAssetExportSession fails if tracks have no segments at all.
                track.insertEmptyTimeRange(CMTimeRange(start: .zero, duration: targetDuration))
                stillImages.append(loaded.ciImage)
                if let ciImage = loaded.ciImage, sourceFraming == .fill {
                    let analysis = HumanRectanglesFraming.analyze(ciImage: ciImage.transformed(by: composedTransform))
                    layerPersonBounds.append(analysis.bestObservation?.boundingBox)
                } else {
                    layerPersonBounds.append(nil)
                }
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
                if sourceFraming == .fill {
                    layerPersonBounds.append(detectPersonBoundsInVideoSource(loaded: loaded, source: source, composedTransform: composedTransform))
                } else {
                    layerPersonBounds.append(nil)
                }

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
            layerPersonBounds: layerPersonBounds,
            sourceFraming: sourceFraming,
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
            instructions: [instruction]
        )

        // Success logging removed to reduce noise
        return .success(result)
    }

    private func detectPersonBoundsInVideoSource(
        loaded: LoadedSource,
        source: HypnogramSource,
        composedTransform: CGAffineTransform
    ) -> CGRect? {
        let generator = AVAssetImageGenerator(asset: loaded.asset)
        generator.appliesPreferredTrackTransform = false
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero

        let clipStartSeconds = source.clip.startTime.seconds
        let clipDurationSeconds = source.clip.duration.seconds
        guard clipStartSeconds.isFinite, clipDurationSeconds.isFinite else { return nil }

        let offsets: [Double] = [
            0.0,
            min(0.25, max(0.0, clipDurationSeconds * 0.05)),
            min(0.75, max(0.0, clipDurationSeconds * 0.20))
        ]
        let times: [CMTime] = offsets
            .map { clipStartSeconds + $0 }
            .filter { $0 >= 0 }
            .map { CMTime(seconds: $0, preferredTimescale: 600) }

        var best: (bbox: CGRect, score: Double)?

        for t in times {
            guard let cgImage = try? generator.copyCGImage(at: t, actualTime: nil) else { continue }
            let ciImage = CIImage(cgImage: cgImage).transformed(by: composedTransform)
            let analysis = HumanRectanglesFraming.analyze(ciImage: ciImage)
            guard let obs = analysis.bestObservation else { continue }

            let area = Double(obs.boundingBox.width * obs.boundingBox.height)
            let score = Double(obs.confidence) * area
            if let current = best {
                if score > current.score { best = (obs.boundingBox, score) }
            } else {
                best = (obs.boundingBox, score)
            }
        }

        return best?.bbox
    }
}
