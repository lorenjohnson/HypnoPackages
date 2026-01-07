import Foundation
import AVFoundation
import CoreMedia
import CoreGraphics
import CoreImage

// MARK: - Core Data Models

public enum MediaKind: String, Codable {
    case video
    case image
}

// MARK: - Media Type

public enum MediaType: String, Codable, CaseIterable {
    case images
    case videos
}

// MARK: - Library Keys

/// Standard keys for media source selection across both Hypnograph and Divine.
public enum ApplePhotosLibraryKeys {
    /// Key for "All Items" from Photos library.
    public static let photosAll = "photos:all"

    /// Key for custom-selected Photos assets.
    public static let photosCustom = "photos:custom"

    /// Key for all folder libraries combined.
    public static let foldersAll = "folders:all"

    /// Prefix for all Photos-related keys.
    public static let photosPrefix = "photos:"
}

// MARK: - Codable Helpers for Core Types

/// Codable wrapper for CMTime (stores as seconds)
public struct CodableCMTime: Codable {
    public let seconds: Double

    public init(_ time: CMTime) {
        self.seconds = time.seconds.isFinite ? time.seconds : 0
    }

    public var cmTime: CMTime {
        CMTime(seconds: seconds, preferredTimescale: 600)
    }
}

/// Codable wrapper for CGAffineTransform
public struct CodableCGAffineTransform: Codable {
    public let a: CGFloat
    public let b: CGFloat
    public let c: CGFloat
    public let d: CGFloat
    public let tx: CGFloat
    public let ty: CGFloat

    public init(_ transform: CGAffineTransform) {
        self.a = transform.a
        self.b = transform.b
        self.c = transform.c
        self.d = transform.d
        self.tx = transform.tx
        self.ty = transform.ty
    }

    public var transform: CGAffineTransform {
        CGAffineTransform(a: a, b: b, c: c, d: d, tx: tx, ty: ty)
    }
}

// MARK: - Media Source

/// Where media comes from - either a local URL or an external source (e.g., Apple Photos).
/// External sources use an opaque identifier that apps resolve via HypnoCoreHooks.
public enum MediaSource: Codable {
    case url(URL)
    case external(identifier: String)

    private enum CodingKeys: String, CodingKey {
        case type, path, identifier
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let type = try container.decode(String.self, forKey: .type)
        switch type {
        case "url":
            let path = try container.decode(String.self, forKey: .path)
            self = .url(URL(fileURLWithPath: path))
        case "external", "photos":  // "photos" for backwards compatibility
            let id: String
            if let identifier = try container.decodeIfPresent(String.self, forKey: .identifier) {
                id = identifier
            } else {
                // Legacy format used "localIdentifier" key
                id = try container.decode(String.self, forKey: CodingKeys(stringValue: "localIdentifier")!)
            }
            self = .external(identifier: id)
        default:
            throw DecodingError.dataCorruptedError(forKey: .type, in: container, debugDescription: "Unknown source type: \(type)")
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .url(let url):
            try container.encode("url", forKey: .type)
            try container.encode(url.path, forKey: .path)
        case .external(let id):
            try container.encode("external", forKey: .type)
            try container.encode(id, forKey: .identifier)
        }
    }
}

// MARK: - Media File

/// A single media file that we can select clips from.
/// Abstracts over local files and external sources (e.g., Apple Photos).
public struct MediaFile: Identifiable, Codable {

    public let id: UUID
    public let source: MediaSource
    public let mediaKind: MediaKind
    public let duration: CMTime

    private enum CodingKeys: String, CodingKey {
        case id, source, mediaKind, duration
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        source = try container.decode(MediaSource.self, forKey: .source)
        mediaKind = try container.decode(MediaKind.self, forKey: .mediaKind)
        let codableDuration = try container.decode(CodableCMTime.self, forKey: .duration)
        duration = codableDuration.cmTime
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(source, forKey: .source)
        try container.encode(mediaKind, forKey: .mediaKind)
        try container.encode(CodableCMTime(duration), forKey: .duration)
    }

    // MARK: - Init

    public init(
        id: UUID = UUID(),
        source: MediaSource,
        mediaKind: MediaKind = .video,
        duration: CMTime
    ) {
        self.id = id
        self.source = source
        self.mediaKind = mediaKind
        self.duration = duration
    }

    /// Convenience init for URL-based sources (most common case)
    public init(
        id: UUID = UUID(),
        url: URL,
        mediaKind: MediaKind = .video,
        duration: CMTime
    ) {
        self.init(id: id, source: .url(url), mediaKind: mediaKind, duration: duration)
    }

    // MARK: - Accessors

    /// Display name for HUD/UI
    public var displayName: String {
        switch source {
        case .url(let url): return url.lastPathComponent
        case .external(let id): return "External:\(id.prefix(8))"
        }
    }

    // MARK: - Asset Loading

    /// Get AVAsset for video sources (async - works for all source types)
    /// External sources are resolved via HypnoCoreHooks.resolveExternalVideo
    public func loadAsset() async -> AVAsset? {
        switch source {
        case .url(let url):
            return AVURLAsset(url: url)
        case .external(let identifier):
            return await HypnoCoreHooks.shared.resolveExternalVideo?(identifier)
        }
    }

    /// Load CIImage for still image sources
    /// External sources are resolved via HypnoCoreHooks.resolveExternalImage
    public func loadImage() async -> CIImage? {
        guard mediaKind == .image else { return nil }
        switch source {
        case .url(let url):
            return StillImageCache.ciImage(for: url)
        case .external(let identifier):
            return await HypnoCoreHooks.shared.resolveExternalImage?(identifier)
        }
    }

    /// Load CGImage for still image sources (used by Divine for thumbnails)
    /// External sources are resolved via HypnoCoreHooks.resolveExternalImage
    public func loadCGImage() async -> CGImage? {
        guard mediaKind == .image else { return nil }
        switch source {
        case .url(let url):
            return StillImageCache.cgImage(for: url)
        case .external(let identifier):
            // Get CIImage via hook and convert to CGImage
            guard let ciImage = await HypnoCoreHooks.shared.resolveExternalImage?(identifier) else {
                return nil
            }
            let context = CIContext()
            return context.createCGImage(ciImage, from: ciImage.extent)
        }
    }
}

// MARK: - Source Library Info

/// Information about a media source library for menu display.
/// Used by both Hypnograph and Divine apps.
public struct SourceLibraryInfo: Identifiable, Sendable {
    public enum LibraryType: Sendable {
        case folders
        case applePhotos
    }

    public let id: String
    public let name: String
    public let type: LibraryType
    public var assetCount: Int

    public init(id: String, name: String, type: LibraryType, assetCount: Int) {
        self.id = id
        self.name = name
        self.type = type
        self.assetCount = assetCount
    }

    /// Display name with asset count, e.g. "Archive (587)"
    public var displayName: String {
        "\(name) (\(assetCount))"
    }
}

// MARK: - Video Clip

/// A specific slice (start + length) from a MediaFile.
public struct VideoClip: Codable {
    public let file: MediaFile
    public let startTime: CMTime
    public let duration: CMTime

    private enum CodingKeys: String, CodingKey {
        case file, startTime, duration
    }

    public init(file: MediaFile, startTime: CMTime, duration: CMTime) {
        self.file = file
        self.startTime = startTime
        self.duration = duration
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        file = try container.decode(MediaFile.self, forKey: .file)
        startTime = try container.decode(CodableCMTime.self, forKey: .startTime).cmTime
        duration = try container.decode(CodableCMTime.self, forKey: .duration).cmTime
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(file, forKey: .file)
        try container.encode(CodableCMTime(startTime), forKey: .startTime)
        try container.encode(CodableCMTime(duration), forKey: .duration)
    }
}
