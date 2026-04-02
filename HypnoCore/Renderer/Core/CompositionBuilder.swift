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

    /// Build a montage from a composition.
    /// - Parameters:
    ///   - composition: The composition to build
    ///   - outputSize: Output dimensions
    ///   - frameRate: Output frame rate
    ///   - enableEffects: Whether to apply effects
    ///   - effectManager: The EffectManager to use for this composition.
    ///                  Pass nil only for legacy callers; all new code should provide a manager.
    func build(
        composition: Composition,
        outputSize: CGSize,
        frameRate: Int = 30,
        enableEffects: Bool = true,
        sourceFraming: SourceFraming = .fill,
        framingHook: (any FramingHook)? = HumanCenteringFramingHook.shared,
        effectManager: EffectManager? = nil
    ) async -> Result<BuildResult, RenderError> {

        // Validate
        guard !composition.layers.isEmpty else {
            return .failure(.noSources)
        }

        guard outputSize.width > 0 && outputSize.height > 0 else {
            return .failure(.invalidOutputSize(outputSize))
        }

        return await buildMontage(
            composition: composition,
            targetDuration: composition.effectiveDuration,
            outputSize: outputSize,
            frameRate: frameRate,
            enableEffects: enableEffects,
            sourceFraming: sourceFraming,
            framingHook: framingHook,
            effectManager: effectManager
        )
    }

    // MARK: - Montage Builder

    private func buildMontage(
        composition: Composition,
        targetDuration: CMTime,
        outputSize: CGSize,
        frameRate: Int,
        enableEffects: Bool,
        sourceFraming: SourceFraming,
        framingHook: (any FramingHook)?,
        effectManager: EffectManager?
    ) async -> Result<BuildResult, RenderError> {

        // Load all sources
        var loadedSources: [(sourceIndex: Int, layer: Layer, loaded: LoadedSource)] = []

        for (index, layer) in composition.layers.enumerated() {
            let result = await sourceLoader.load(layer: layer)

            switch result {
            case .success(let loaded):
                loadedSources.append((sourceIndex: index, layer: layer, loaded: loaded))
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
        let avComposition = AVMutableComposition()
        let renderID = UUID()
        var trackIDs: [CMPersistentTrackID] = []
        var audioTrackIDs: [CMPersistentTrackID] = []
        var transforms: [CGAffineTransform] = []
        var blendModes: [String] = []
        var sourceIndices: [Int] = []
        var stillImages: [CIImage?] = []

        for (index, entry) in loadedSources.enumerated() {
            let layer = entry.layer
            let loaded = entry.loaded
            guard let track = avComposition.addMutableTrack(
                withMediaType: .video,
                preferredTrackID: kCMPersistentTrackID_Invalid
            ) else {
                print("🔴 Failed to create track \(index)")
                continue
            }

            // Compose metadata transform with user transforms array
            let userTransform = layer.transforms.reduce(CGAffineTransform.identity) { $0.concatenating($1) }
            let composedTransform = loaded.transform.concatenating(userTransform)

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

                let (effectiveStartTime, effectiveClipDuration) = normalizedClipSlice(
                    clipID: composition.id,
                    sourceIndex: entry.sourceIndex,
                    sourceClip: layer.mediaClip,
                    fileID: layer.mediaClip.file.id,
                    assetDuration: loaded.duration,
                    targetDuration: targetDuration
                )
                var currentTime = CMTime.zero
                var loopCount = 0

                while currentTime < targetDuration {
                    let remainingDuration = CMTimeSubtract(targetDuration, currentTime)
                    let insertDuration = CMTimeMinimum(effectiveClipDuration, remainingDuration)
                    let insertRange = CMTimeRange(start: effectiveStartTime, duration: insertDuration)

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
                if !layer.isMuted, let audioTrack = loaded.audioTrack {
                    guard let compAudioTrack = avComposition.addMutableTrack(
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
                        let insertDuration = CMTimeMinimum(effectiveClipDuration, remainingDuration)
                        let insertRange = CMTimeRange(start: effectiveStartTime, duration: insertDuration)

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
            let blendMode = layer.blendMode ?? (index == 0 ? BlendMode.sourceOver : BlendMode.defaultMontage)
            blendModes.append(blendMode)
        }

        guard !trackIDs.isEmpty else {
            return .failure(.allSourcesFailedToLoad)
        }

        // If we have still images, we need to ensure composition has duration
        // (empty tracks don't extend composition duration)
        if avComposition.duration.seconds <= 0 {
            avComposition.insertEmptyTimeRange(CMTimeRange(start: .zero, duration: targetDuration))
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
            sourceFraming: sourceFraming,
            framingHook: framingHook,
            renderID: renderID,
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
            composition: avComposition,
            videoComposition: videoComposition,
            audioMix: audioMix,
            instructions: [instruction]
        )

        // Success logging removed to reduce noise
        return .success(result)
    }

    /// Normalize a video slice so that:
    /// - We respect the layer's selected `sourceClip.duration` as the playable window.
    /// - We preserve `sourceClip.startTime` when it remains valid for that window.
    /// - If start is invalid/out-of-bounds, we choose a deterministic pseudo-random valid start.
    /// - The caller can still loop this window to cover `targetDuration`.
    private func normalizedClipSlice(
        clipID: UUID,
        sourceIndex: Int,
        sourceClip: MediaClip,
        fileID: UUID,
        assetDuration: CMTime,
        targetDuration: CMTime
    ) -> (startTime: CMTime, duration: CMTime) {
        guard assetDuration.isValid, assetDuration.isNumeric else {
            return (sourceClip.startTime, sourceClip.duration)
        }
        guard targetDuration.isValid, targetDuration.isNumeric else {
            return (sourceClip.startTime, sourceClip.duration)
        }

        let assetPositive = CMTimeMaximum(assetDuration, .zero)
        let targetPositive = CMTimeMaximum(targetDuration, .zero)

        guard CMTimeCompare(assetPositive, .zero) > 0, CMTimeCompare(targetPositive, .zero) > 0 else {
            return (sourceClip.startTime, sourceClip.duration)
        }

        // Use the per-layer selected duration window when available.
        let selectedDuration: CMTime = {
            if sourceClip.duration.isValid, sourceClip.duration.isNumeric,
               CMTimeCompare(sourceClip.duration, .zero) > 0 {
                return sourceClip.duration
            }
            // Legacy fallback for clips without explicit per-layer duration.
            return targetPositive
        }()

        // Effective loop window cannot exceed the source asset duration.
        let loopWindow = CMTimeMinimum(CMTimeMaximum(selectedDuration, .zero), assetPositive)
        guard CMTimeCompare(loopWindow, .zero) > 0 else {
            return (.zero, assetPositive)
        }

        let maxStart = CMTimeSubtract(assetPositive, loopWindow)
        if CMTimeCompare(sourceClip.startTime, .zero) >= 0,
           CMTimeCompare(sourceClip.startTime, maxStart) <= 0 {
            return (sourceClip.startTime, loopWindow)
        }

        let start = deterministicRandomStartTime(
            clipID: clipID,
            sourceIndex: sourceIndex,
            fileID: fileID,
            maxStart: maxStart,
            preferredTimescale: loopWindow.timescale
        )
        return (start, loopWindow)
    }

    private func deterministicRandomStartTime(
        clipID: UUID,
        sourceIndex: Int,
        fileID: UUID,
        maxStart: CMTime,
        preferredTimescale: CMTimeScale
    ) -> CMTime {
        let maxStartSeconds = maxStart.seconds
        guard maxStartSeconds.isFinite, maxStartSeconds > 0 else { return .zero }

        let seed = stableSeed(
            clipID: clipID,
            sourceIndex: sourceIndex,
            fileID: fileID,
            maxStartSeconds: maxStartSeconds,
            timescale: preferredTimescale
        )
        let unit = randomUnitDouble(seed: seed)
        let startSeconds = max(0.0, min(maxStartSeconds, unit * maxStartSeconds))
        return CMTime(seconds: startSeconds, preferredTimescale: preferredTimescale)
    }

    private func stableSeed(
        clipID: UUID,
        sourceIndex: Int,
        fileID: UUID,
        maxStartSeconds: Double,
        timescale: CMTimeScale
    ) -> UInt64 {
        var h: UInt64 = 14695981039346656037 // FNV-1a offset basis
        func mixBytes<T>(_ value: inout T) {
            withUnsafeBytes(of: &value) { bytes in
                for b in bytes {
                    h ^= UInt64(b)
                    h = h &* 1099511628211
                }
            }
        }

        var clip = clipID.uuid
        var file = fileID.uuid
        mixBytes(&clip)
        mixBytes(&file)

        var si = Int64(sourceIndex)
        mixBytes(&si)

        // Fold timing inputs to avoid floating-point instability.
        var ms = Int64((maxStartSeconds * 1000.0).rounded(.toNearestOrAwayFromZero))
        mixBytes(&ms)

        var ts = Int64(timescale)
        mixBytes(&ts)

        return h
    }

    private func randomUnitDouble(seed: UInt64) -> Double {
        // SplitMix64
        var x = seed &+ 0x9E3779B97F4A7C15
        x = (x ^ (x >> 30)) &* 0xBF58476D1CE4E5B9
        x = (x ^ (x >> 27)) &* 0x94D049BB133111EB
        x = x ^ (x >> 31)

        // Convert top 53 bits to [0, 1)
        let mantissa = x >> 11
        return Double(mantissa) / Double(1 << 53)
    }

}
