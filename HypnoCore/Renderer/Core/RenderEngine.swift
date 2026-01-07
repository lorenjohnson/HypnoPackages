//
//  RenderEngine.swift
//  Hypnograph
//
//  Unified engine for preview and export
//  Skeleton: preview only, single source
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
        public let enableGlobalEffects: Bool  // false for export

        public init(
            outputSize: CGSize,
            frameRate: Int,
            enableGlobalEffects: Bool
        ) {
            self.outputSize = outputSize
            self.frameRate = frameRate
            self.enableGlobalEffects = enableGlobalEffects
        }

        public static let preview = Config(
            outputSize: CGSize(width: 1920, height: 1080),
            frameRate: 30,
            enableGlobalEffects: true
        )
    }

    public enum Timeline {
        case montage(targetDuration: CMTime)
        case sequence
    }
    
    // MARK: - Dependencies
    
    private let compositionBuilder = CompositionBuilder()

    public init() {}
    
    // MARK: - Preview

    /// Result of making a player item
    public struct PlayerItemResult {
        public let playerItem: AVPlayerItem
        public let clipStartTimes: [CMTime]
        /// Still images for each source index (for sequence mode override when seeking to still images)
        public let stillImagesBySourceIndex: [Int: CIImage]
    }

    /// Build a player item for preview or isolated playback
    /// - Parameters:
    ///   - recipe: The recipe to build
    ///   - timeline: Montage or sequence timeline
    ///   - config: Render configuration
    ///   - effectManager: The EffectManager to use. If nil, uses global effects.
    public func makePlayerItem(
        recipe: HypnogramRecipe,
        timeline: Timeline,
        config: Config,
        effectManager: EffectManager? = nil
    ) async -> Result<PlayerItemResult, RenderError> {

        let strategy = mapTimeline(timeline)

        // Build composition
        let buildResult = await compositionBuilder.build(
            recipe: recipe,
            strategy: strategy,
            outputSize: config.outputSize,
            frameRate: config.frameRate,
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

        // Create player item
        let playerItem = AVPlayerItem(asset: build.composition)
        playerItem.videoComposition = build.videoComposition

        // Extract still images by source index from instructions (for sequence mode)
        var stillImagesBySourceIndex: [Int: CIImage] = [:]
        for instruction in build.instructions {
            for (layerIndex, sourceIndex) in instruction.sourceIndices.enumerated() {
                if layerIndex < instruction.stillImages.count,
                   let stillImage = instruction.stillImages[layerIndex] {
                    stillImagesBySourceIndex[sourceIndex] = stillImage
                }
            }
        }

        let result = PlayerItemResult(
            playerItem: playerItem,
            clipStartTimes: build.clipStartTimes,
            stillImagesBySourceIndex: stillImagesBySourceIndex
        )

        return .success(result)
    }

    /// Build a player item for a single source (used by sequence mode per-clip playback)
    public func makePlayerItemForSource(
        _ source: HypnogramSource,
        sourceIndex: Int,
        outputSize: CGSize,
        frameRate: Int = 30,
        enableEffects: Bool = true,
        effectManager: EffectManager? = nil
    ) async -> Result<AVPlayerItem, RenderError> {
        let buildResult = await compositionBuilder.buildSingleSource(
            source: source,
            sourceIndex: sourceIndex,
            outputSize: outputSize,
            frameRate: frameRate,
            enableEffects: enableEffects,
            effectManager: effectManager
        )

        guard case .success(let build) = buildResult else {
            if case .failure(let error) = buildResult {
                error.log(context: "RenderEngine.makePlayerItemForSource")
                return .failure(error)
            }
            return .failure(.playerItemCreationFailed)
        }

        build.videoComposition.customVideoCompositorClass = FrameCompositor.self

        let playerItem = AVPlayerItem(asset: build.composition)
        playerItem.videoComposition = build.videoComposition
        return .success(playerItem)
    }
    
    // MARK: - Export

    /// Export to file
    public func export(
        recipe: HypnogramRecipe,
        timeline: Timeline,
        outputURL: URL,
        config: Config,
        progress: ((Double) -> Void)? = nil
    ) async -> Result<URL, RenderError> {

        print("🎬 RenderEngine.export: Starting export to \(outputURL.lastPathComponent)...")

        // Create isolated copy of recipe with fresh effect state for export
        // This prevents stateful effects (like TextOverlayEffect) from sharing state with preview
        let exportRecipe = recipe.copyForExport()
        let exportManager = EffectManager.forExport(recipe: exportRecipe)

        // Build composition with the export manager
        let builder = CompositionBuilder()
        let buildResult = await builder.build(
            recipe: exportRecipe,
            strategy: mapTimeline(timeline),
            outputSize: config.outputSize,
            frameRate: config.frameRate,
            enableEffects: config.enableGlobalEffects,
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

        // For montage with all still images, export as PNG instead of video
        if case .montage = timeline {
            let videoTracks = build.composition.tracks(withMediaType: .video)
            let hasActualVideoSegments = videoTracks.contains { track in
                track.segments.contains { !$0.isEmpty }
            }

            if !hasActualVideoSegments, let instruction = build.instructions.first {
                print("🎬 Montage with all still images - exporting as PNG")
                guard let montage = PhotoMontage(instruction: instruction, outputSize: config.outputSize) else {
                    return .failure(.exportFailed(
                        underlying: NSError(domain: "RenderEngine", code: 10,
                            userInfo: [NSLocalizedDescriptionKey: "No images for photo montage"])))
                }
                switch montage.exportPNG(to: outputURL) {
                case .success(let url):
                    print("✅ Export complete (PNG): \(url.lastPathComponent)")
                    return .success(url)
                case .failure(let error):
                    return .failure(.exportFailed(underlying: error))
                }
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

    // MARK: - Export Queue

    public final class ExportQueue {
        public private(set) var activeJobs: Int = 0
        public var onAllJobsFinished: (() -> Void)?
        public var onStatusMessage: ((String) -> Void)?

        public init() {}

        public func enqueue(
            recipe: HypnogramRecipe,
            outputFolder: URL,
            outputSize: CGSize,
            timeline: Timeline,
            frameRate: Int = 30,
            enableGlobalEffects: Bool = true,
            completion: ((Result<URL, RenderError>) -> Void)? = nil
        ) {
            activeJobs += 1
            onStatusMessage?("Rendering started")

            Task {
                let timestamp = ISO8601DateFormatter().string(from: Date())
                    .replacingOccurrences(of: ":", with: "-")
                let filename = "hypnograph-\(timestamp).mov"
                let outputURL = outputFolder.appendingPathComponent(filename)

                try? FileManager.default.removeItem(at: outputURL)

                let config = RenderEngine.Config(
                    outputSize: outputSize,
                    frameRate: frameRate,
                    enableGlobalEffects: enableGlobalEffects
                )

                let engine = RenderEngine()
                let result = await engine.export(
                    recipe: recipe,
                    timeline: timeline,
                    outputURL: outputURL,
                    config: config
                )

                await MainActor.run {
                    self.activeJobs -= 1

                    switch result {
                    case .success(let url):
                        print("Render job finished: \(url.path)")
                        self.onStatusMessage?("Saved: \(url.lastPathComponent)")

                        // Notify via hook for external destinations (e.g., Apple Photos)
                        if let hook = HypnoCoreHooks.shared.onVideoExportCompleted {
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
    }

    // MARK: - Timeline Mapping

    private func mapTimeline(_ timeline: Timeline) -> CompositionBuilder.TimelineStrategy {
        switch timeline {
        case .montage(let targetDuration):
            return .montage(targetDuration: targetDuration)
        case .sequence:
            return .sequence
        }
    }
}
