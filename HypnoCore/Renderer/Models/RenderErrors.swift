//
//  RenderErrors.swift
//  HypnoRenderer
//
//  Typed errors for the render pipeline with clear, loggable messages
//

import Foundation
import AVFoundation

public enum RenderError: Error, CustomStringConvertible, LocalizedError {
    case noSources
    case invalidDuration(CMTime)
    case sourceLoadFailed(index: Int, name: String, underlying: Error)
    case noVideoTrack(name: String)
    case noAssetTrack(name: String)
    case imageLoadFailed(name: String, underlying: Error)
    case compositionBuildFailed(underlying: Error)
    case exportFailed(underlying: Error)
    case allSourcesFailedToLoad
    case invalidOutputSize(CGSize)
    case playerItemCreationFailed

    public var description: String {
        switch self {
        case .noSources:
            return "RenderError: No sources provided in recipe"

        case .invalidDuration(let duration):
            return "RenderError: Invalid duration \(duration.seconds)s"

        case .sourceLoadFailed(let index, let name, let error):
            return "RenderError: Source[\(index)] failed to load from \(name): \(error.localizedDescription)"

        case .noVideoTrack(let name):
            return "RenderError: No video track found in \(name)"

        case .noAssetTrack(let name):
            return "RenderError: No asset track found in \(name)"

        case .imageLoadFailed(let name, let error):
            return "RenderError: Image failed to load from \(name): \(error.localizedDescription)"

        case .compositionBuildFailed(let error):
            return "RenderError: Composition build failed: \(error.localizedDescription)"

        case .exportFailed(let error):
            return "RenderError: Export failed: \(error.localizedDescription)"

        case .allSourcesFailedToLoad:
            return "RenderError: All sources failed to load"

        case .invalidOutputSize(let size):
            return "RenderError: Invalid output size \(size)"

        case .playerItemCreationFailed:
            return "RenderError: Failed to create AVPlayerItem"
        }
    }

    public var errorDescription: String? {
        description
    }
    
    /// Log this error with context
    public func log(context: String = "") {
        let prefix = context.isEmpty ? "" : "[\(context)] "
        print("🔴 \(prefix)\(description)")
    }
}
