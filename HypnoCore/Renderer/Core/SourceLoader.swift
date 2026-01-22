//
//  SourceLoader.swift
//  HypnoRenderer
//
//  Loads and validates video/image sources with graceful error handling
//

import Foundation
import AVFoundation
import CoreImage
import CoreGraphics

/// Represents a successfully loaded source ready for composition
struct LoadedSource {
    let asset: AVAsset
    let videoTrack: AVAssetTrack?  // nil for still images (they use ciImage instead)
    let audioTrack: AVAssetTrack?  // nil if no audio
    let duration: CMTime
    let naturalSize: CGSize
    let transform: CGAffineTransform  // embedded orientation from EXIF/metadata
    let isStillImage: Bool
    let ciImage: CIImage?  // For still images - the actual image data
}

/// Loads sources with fault tolerance and caching
final class SourceLoader {

    // MARK: - Cache

    /// Cache of loaded sources by file identifier
    /// This prevents reloading the same asset multiple times during composition builds
    private static var cache: [String: LoadedSource] = [:]
    private static let cacheQueue = DispatchQueue(label: "com.hypnograph.sourceloader.cache")

    /// Clear the source cache (call when sources change)
    static func clearCache() {
        cacheQueue.sync {
            cache.removeAll()
        }
    }

    /// Remove a specific source from cache
    static func invalidate(fileID: String) {
        cacheQueue.sync {
            _ = cache.removeValue(forKey: fileID)
        }
    }

    // MARK: - Loading

    /// Load a source, return error if it fails (never crashes)
    /// Uses caching to avoid reloading the same source multiple times
    func load(source: HypnogramLayer) async -> Result<LoadedSource, RenderError> {
        let file = source.mediaClip.file
        let cacheKey = file.id.uuidString

        // Check cache first
        if let cached = Self.cacheQueue.sync(execute: { Self.cache[cacheKey] }) {
            return .success(cached)
        }

        // Load and cache
        let result: Result<LoadedSource, RenderError>
        switch file.mediaKind {
        case .image:
            result = await loadImageSource(source: source)
        case .video:
            result = await loadVideoSource(source: source)
        }

        // Cache successful loads
        if case .success(let loaded) = result {
            Self.cacheQueue.sync {
                Self.cache[cacheKey] = loaded
            }
        }

        return result
    }
    
    // MARK: - Video Loading

    private func loadVideoSource(source: HypnogramLayer) async -> Result<LoadedSource, RenderError> {
        let file = source.mediaClip.file

        // Get AVAsset - either from URL or external source via hooks
        let asset: AVAsset
        switch file.source {
        case .url(let url):
            asset = AVURLAsset(url: url)
        case .external(let identifier):
            guard let avAsset = await HypnoCoreHooks.shared.resolveExternalVideo?(identifier) else {
                return .failure(.sourceLoadFailed(
                    index: -1,
                    name: file.displayName,
                    underlying: NSError(domain: "SourceLoader", code: 2,
                        userInfo: [NSLocalizedDescriptionKey: "Failed to load video from external source (hook not configured or returned nil)"])
                ))
            }
            asset = avAsset
        }

        do {
            let videoTracks = try await asset.loadTracks(withMediaType: .video)

            guard let videoTrack = videoTracks.first else {
                return .failure(.noVideoTrack(name: file.displayName))
            }

            let naturalSize = try await videoTrack.load(.naturalSize)
            let preferredTransform = try await videoTrack.load(.preferredTransform)
            let timeRange = try await videoTrack.load(.timeRange)

            // Convert AVFoundation transform to CIImage coordinate system
            let ciTransform = RendererImageUtils.convertTransformForCIImage(preferredTransform, naturalSize: naturalSize)

            let audioTracks = try await asset.loadTracks(withMediaType: .audio)
            let audioTrack = audioTracks.first

            return .success(LoadedSource(
                asset: asset,
                videoTrack: videoTrack,
                audioTrack: audioTrack,
                duration: timeRange.duration,
                naturalSize: naturalSize,
                transform: ciTransform,
                isStillImage: false,
                ciImage: nil
            ))
        } catch {
            return .failure(.sourceLoadFailed(index: -1, name: file.displayName, underlying: error))
        }
    }

    // MARK: - Image Loading

    private func loadImageSource(source: HypnogramLayer) async -> Result<LoadedSource, RenderError> {
        let file = source.mediaClip.file

        // Get CIImage - either from URL or external source via hooks
        let ciImage: CIImage?
        switch file.source {
        case .url(let url):
            ciImage = StillImageCache.ciImage(for: url)
        case .external(let identifier):
            ciImage = await HypnoCoreHooks.shared.resolveExternalImage?(identifier)
        }

        guard let ciImage = ciImage else {
            return .failure(.imageLoadFailed(
                name: file.displayName,
                underlying: NSError(domain: "SourceLoader", code: 1,
                    userInfo: [NSLocalizedDescriptionKey: "Failed to decode image"])
            ))
        }

        let extent = ciImage.extent

        // For external images, we need a dummy asset - use an empty composition
        let dummyAsset: AVAsset
        switch file.source {
        case .url(let url):
            dummyAsset = AVURLAsset(url: url)
        case .external:
            dummyAsset = AVMutableComposition()
        }

        return .success(LoadedSource(
            asset: dummyAsset,
            videoTrack: nil,
            audioTrack: nil,
            duration: source.mediaClip.duration,
            naturalSize: CGSize(width: extent.width, height: extent.height),
            transform: .identity,  // CIImage orientation already applied
            isStillImage: true,
            ciImage: ciImage
        ))
    }
}
