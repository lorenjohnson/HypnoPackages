//
//  FrameBufferPreloader.swift
//  Hypnograph
//
//  Handles prerolling/prefilling the frame buffer before playback.
//  Only runs when temporal effects are active and RendererConfig.prerollEnabled is true.
//

import Foundation
import AVFoundation
import CoreImage

/// Preloads frame buffer for temporal effects before playback starts
enum FrameBufferPreloader {

    /// Preload result
    enum PreloadResult {
        case success(frameCount: Int)
        case skipped(reason: String)
        case failed(reason: String)
    }

    /// Preload the frame buffer for a video asset
    /// - Parameters:
    ///   - asset: The video asset to preload frames from
    ///   - frameBuffer: The frame buffer to fill
    ///   - effectManager: Effect manager to check if preload is needed
    ///   - startTime: Start time for preroll (default: .zero)
    /// - Returns: Result of the preload operation
    static func preload(
        asset: AVAsset,
        frameBuffer: FrameBuffer,
        effectManager: EffectManager,
        startTime: CMTime = .zero
    ) async -> PreloadResult {
        // Check global preroll flag
        guard RendererConfig.prerollEnabled else {
            return .skipped(reason: "Preroll disabled")
        }

        // Check if preload is needed based on effects
        guard effectManager.usesFrameBuffer else {
            return .skipped(reason: "No temporal effects")
        }

        let requiredFrames = min(effectManager.maxRequiredLookback, frameBuffer.maxFrames)
        guard requiredFrames > 0 else {
            return .skipped(reason: "Zero lookback required")
        }

        print("🎬 FrameBufferPreloader: Prerolling \(requiredFrames) frames...")

        // Perform preroll
        let count = await frameBuffer.preroll(
            from: asset,
            startTime: startTime,
            frameCount: requiredFrames
        )

        if count > 0 {
            print("✅ FrameBufferPreloader: Preroll complete, \(count) frames")
            return .success(frameCount: count)
        } else {
            print("⚠️ FrameBufferPreloader: Preroll failed")
            return .failed(reason: "No frames loaded from asset")
        }
    }

    /// Preload the frame buffer for a still image
    /// - Parameters:
    ///   - image: The still image to prefill with
    ///   - frameBuffer: The frame buffer to fill
    ///   - effectManager: Effect manager to check if preload is needed
    /// - Returns: Result of the preload operation
    static func preload(
        image: CIImage,
        frameBuffer: FrameBuffer,
        effectManager: EffectManager
    ) -> PreloadResult {
        // Check global preroll flag
        guard RendererConfig.prerollEnabled else {
            return .skipped(reason: "Preroll disabled")
        }

        // Check if preload is needed based on effects
        guard effectManager.usesFrameBuffer else {
            return .skipped(reason: "No temporal effects")
        }

        let requiredFrames = min(effectManager.maxRequiredLookback, frameBuffer.maxFrames)
        guard requiredFrames > 0 else {
            return .skipped(reason: "Zero lookback required")
        }

        print("🖼️ FrameBufferPreloader: Prefilling \(requiredFrames) frames...")

        let count = frameBuffer.prefill(with: image, frameCount: requiredFrames)

        if count > 0 {
            print("✅ FrameBufferPreloader: Prefill complete, \(count) frames")
            return .success(frameCount: count)
        } else {
            print("⚠️ FrameBufferPreloader: Prefill failed")
            return .failed(reason: "Prefill returned 0 frames")
        }
    }
}

