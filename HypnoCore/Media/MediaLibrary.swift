import Foundation
import AVFoundation
import CoreMedia
import CoreImage
import Photos

// MARK: - MediaLibrary

public final class MediaLibrary {
    // MARK: - Lazy Loading Optimization
    // For large libraries (5000+ files), we use a two-tier approach:
    // 1. Lightweight index: just source + media kind (fast startup, low memory)
    // 2. Lazy metadata loading: only load AVAsset/duration when file is selected

    private struct SourceEntry {
        let source: MediaSource
        let mediaKind: MediaKind
    }

    private var sourceIndex: [SourceEntry] = []

    /// Sources that have failed validation at selection time (in-memory only).
    private var badSources = Set<String>()

    /// Which media types to include
    private let allowedMediaTypes: Set<MediaType>
    private let exclusionStore: ExclusionStore

    let allowedPhotoExtensions = Set([
        "jpeg", "jpg", "png", "heic", "gif"
    ])

    let allowVideoExtensions = Set([
        "mov", "mp4", "m4v", "webm",
        "hevc", "avi", "mkv",
        "3gp", "3g2"
    ])

    /// Whether images are allowed based on media types
    private var allowImages: Bool { allowedMediaTypes.contains(.images) }
    /// Whether videos are allowed based on media types
    private var allowVideos: Bool { allowedMediaTypes.contains(.videos) }

    /// Total number of assets in this library
    public var assetCount: Int { sourceIndex.count }

    public init(
        sources: [String],
        allowedMediaTypes: Set<MediaType> = [.images, .videos],
        exclusionStore: ExclusionStore
    ) {
        self.allowedMediaTypes = allowedMediaTypes
        self.exclusionStore = exclusionStore
        if sources.isEmpty {
            // No explicit sources → default to Photos library videos
            loadFilesFromPhotosLibrary()
        } else {
            // Explicit folders / files → current behavior
            loadFiles(from: sources)
        }
        applyExclusions()
    }

    /// Initialize from a Photos album
    public init(
        photosAlbum: PHAssetCollection,
        allowedMediaTypes: Set<MediaType> = [.images, .videos],
        exclusionStore: ExclusionStore
    ) {
        self.allowedMediaTypes = allowedMediaTypes
        self.exclusionStore = exclusionStore
        loadFromPhotosAlbum(photosAlbum)
        applyExclusions()
    }

    /// Initialize from both folder paths AND Photos albums (combined sources)
    /// Set `includeAllPhotos` to true to include all items from Photos library
    /// Use `customPhotosAssetIds` to include specific Photos assets by local identifier
    public init(
        sources: [String],
        photosAlbums: [PHAssetCollection] = [],
        includeAllPhotos: Bool = false,
        customPhotosAssetIds: [String] = [],
        allowedMediaTypes: Set<MediaType> = [.images, .videos],
        exclusionStore: ExclusionStore
    ) {
        self.allowedMediaTypes = allowedMediaTypes
        self.exclusionStore = exclusionStore

        /// Load folder/file sources
        if !sources.isEmpty {
            loadFiles(from: sources)
            applyExclusions()
        }

        // Load all Photos library items if requested (takes precedence over specific albums)
        if includeAllPhotos {
            loadAllPhotosAssets()
        } else {
            // Load Photos album sources
            for album in photosAlbums {
                loadFromPhotosAlbum(album)
            }
        }

        // Load custom-selected Photos assets
        if !customPhotosAssetIds.isEmpty {
            loadFromPhotosAssetIds(customPhotosAssetIds)
        }

        applyExclusions()
        print("MediaLibrary: combined library has \(sourceIndex.count) total sources")
    }

    /// Load specific Photos assets by their local identifiers
    private func loadFromPhotosAssetIds(_ identifiers: [String]) {
        guard ApplePhotos.shared.status.canRead else { return }

        let assets = PHAsset.fetchAssets(withLocalIdentifiers: identifiers, options: nil)
        var results: [SourceEntry] = []

        for i in 0..<assets.count {
            let asset = assets.object(at: i)

            switch asset.mediaType {
            case .video where allowVideos:
                results.append(SourceEntry(source: .external(identifier: asset.localIdentifier), mediaKind: .video))
            case .image where allowImages:
                results.append(SourceEntry(source: .external(identifier: asset.localIdentifier), mediaKind: .image))
            default:
                break
            }
        }

        self.sourceIndex.append(contentsOf: results)
        print("MediaLibrary: indexed \(results.count) assets from custom selection (\(identifiers.count) requested)")
    }

    /// Load all assets from the entire Photos library
    private func loadAllPhotosAssets() {
        guard ApplePhotos.shared.status.canRead else { return }

        var results: [SourceEntry] = []

        let options = PHFetchOptions()
        options.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: false)]

        let allAssets = PHAsset.fetchAssets(with: options)

        for i in 0..<allAssets.count {
            let asset = allAssets.object(at: i)

            switch asset.mediaType {
            case .video where allowVideos:
                results.append(SourceEntry(source: .external(identifier: asset.localIdentifier), mediaKind: .video))
            case .image where allowImages:
                results.append(SourceEntry(source: .external(identifier: asset.localIdentifier), mediaKind: .image))
            default:
                break
            }
        }

        self.sourceIndex.append(contentsOf: results)
        print("MediaLibrary: indexed \(results.count) assets from entire Photos library")
    }

    // MARK: - File system sources

    private func loadFiles(from sources: [String]) {
        let fileManager = FileManager.default
        var results: [SourceEntry] = []

        for path in sources {
            let url = URL(fileURLWithPath: path)

            var isDirectory: ObjCBool = false
            guard fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory) else {
                continue
            }

            if isDirectory.boolValue {
                // Directory case: recurse and collect sources only (no AVAsset creation!)
                guard let enumerator = fileManager.enumerator(
                    at: url,
                    includingPropertiesForKeys: nil
                ) else { continue }

                for case let fileURL as URL in enumerator {
                    var isDir: ObjCBool = false
                    if fileManager.fileExists(atPath: fileURL.path, isDirectory: &isDir),
                       isDir.boolValue {
                        continue
                    }

                    let ext = fileURL.pathExtension.lowercased()

                    if allowVideos && allowVideoExtensions.contains(ext) {
                        results.append(SourceEntry(source: .url(fileURL), mediaKind: .video))
                    } else if allowImages && allowedPhotoExtensions.contains(ext) {
                        results.append(SourceEntry(source: .url(fileURL), mediaKind: .image))
                    }
                }
            } else {
                // Single-file case
                let ext = url.pathExtension.lowercased()

                if allowVideos && allowVideoExtensions.contains(ext) {
                    results.append(SourceEntry(source: .url(url), mediaKind: .video))
                } else if allowImages && allowedPhotoExtensions.contains(ext) {
                    results.append(SourceEntry(source: .url(url), mediaKind: .image))
                }
            }
        }

        self.sourceIndex.append(contentsOf: results)
    }

    // MARK: - Photos library fallback (raw originals scan)

    private func loadFilesFromPhotosLibrary() {
        let fm = FileManager.default
        let picturesDir = fm.urls(for: .picturesDirectory, in: .userDomainMask).first!

        let photosLibURL = picturesDir.appendingPathComponent(
            "Photos Library.photoslibrary",
            isDirectory: true
        )

        let originalsURL = photosLibURL.appendingPathComponent("originals", isDirectory: true)

        guard fm.fileExists(atPath: originalsURL.path) else {
            print("MediaLibrary: Originals folder not found at \(originalsURL.path)")
            self.sourceIndex = []
            return
        }

        let resourceKeys: Set<URLResourceKey> = [
            .isRegularFileKey,
            .fileSizeKey,
            .isReadableKey
        ]

        var results: [SourceEntry] = []

        guard let enumerator = fm.enumerator(
            at: originalsURL,
            includingPropertiesForKeys: Array(resourceKeys),
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else {
            self.sourceIndex = []
            return
        }

        for case let fileURL as URL in enumerator {
            let ext = fileURL.pathExtension.lowercased()

            guard let values = try? fileURL.resourceValues(forKeys: resourceKeys),
                  values.isRegularFile == true,
                  values.isReadable == true else { continue }

            // Skip iCloud placeholders / stubs
            if let size = values.fileSize, size < 1024 { continue }

            if allowVideos && allowVideoExtensions.contains(ext) {
                results.append(SourceEntry(source: .url(fileURL), mediaKind: .video))
            } else if allowImages && allowedPhotoExtensions.contains(ext) {
                results.append(SourceEntry(source: .url(fileURL), mediaKind: .image))
            }
        }

        self.sourceIndex.append(contentsOf: results)
        print("MediaLibrary: indexed \(results.count) media files from Photos originals/")
    }

    // MARK: - Photos Album sources

    private func loadFromPhotosAlbum(_ album: PHAssetCollection) {
        var results: [SourceEntry] = []

        let options = PHFetchOptions()
        options.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: false)]

        let assets = PHAsset.fetchAssets(in: album, options: nil)

        for i in 0..<assets.count {
            let asset = assets.object(at: i)

            switch asset.mediaType {
            case .video where allowVideos:
                results.append(SourceEntry(source: .external(identifier: asset.localIdentifier), mediaKind: .video))
            case .image where allowImages:
                results.append(SourceEntry(source: .external(identifier: asset.localIdentifier), mediaKind: .image))
            default:
                break
            }
        }

        self.sourceIndex.append(contentsOf: results)
        print("MediaLibrary: indexed \(results.count) assets from Photos album '\(album.localizedTitle ?? "unknown")'")
    }

    // MARK: - Random clip selection (with lazy validation for video + image)

    /// If `clipLength` is nil, videos use their full duration and images use `imageDuration`.
    public func randomClip(clipLength: Double? = nil, imageDuration: Double = 0.1) -> VideoClip? {
        // Consider *all* sources except those already marked bad.
        let candidates = sourceIndex.filter { !badSources.contains(sourceKey($0.source)) }
        guard !candidates.isEmpty else {
            print("⚠️ MediaLibrary.randomClip: No candidates (sourceIndex: \(sourceIndex.count), badSources: \(badSources.count))")
            return nil
        }

        let maxAttempts = min(32, max(candidates.count * 2, 1))

        for _ in 0..<maxAttempts {
            guard let entry = candidates.randomElement() else { break }

            switch entry.mediaKind {
            case .video:
                guard let clip = validateVideoSource(entry, clipLength: clipLength) else {
                    badSources.insert(sourceKey(entry.source))
                    continue
                }
                return clip

            case .image:
                let effectiveLength = clipLength ?? imageDuration
                guard let clip = validateImageSource(entry, clipLength: effectiveLength) else {
                    badSources.insert(sourceKey(entry.source))
                    continue
                }
                return clip
            }
        }

        return nil
    }

    // MARK: - Source Validation

    private func validateVideoSource(_ entry: SourceEntry, clipLength: Double?) -> VideoClip? {
        switch entry.source {
        case .url(let url):
            let asset = AVURLAsset(url: url)
            let totalSeconds = asset.duration.seconds

            guard totalSeconds > 0,
                  asset.isPlayable,
                  asset.tracks(withMediaType: .video).first != nil else {
                return nil
            }

            let length = clipLength.map { min($0, totalSeconds) } ?? totalSeconds
            let maxStart = max(0.0, totalSeconds - length)
            let startSeconds = maxStart > 0 ? Double.random(in: 0...maxStart) : 0

            return VideoClip(
                file: MediaFile(
                    source: entry.source,
                    mediaKind: .video,
                    duration: CMTime(seconds: totalSeconds, preferredTimescale: 600)
                ),
                startTime: CMTime(seconds: startSeconds, preferredTimescale: 600),
                duration: CMTime(seconds: length, preferredTimescale: 600)
            )

        case .external(let identifier):
            // Fetch PHAsset to get duration (app-level - uses ApplePhotos directly)
            guard let phAsset = ApplePhotos.shared.fetchAsset(localIdentifier: identifier) else {
                return nil
            }

            let totalSeconds = phAsset.duration
            guard totalSeconds > 0 else { return nil }

            let length = clipLength.map { min($0, totalSeconds) } ?? totalSeconds
            let maxStart = max(0.0, totalSeconds - length)
            let startSeconds = maxStart > 0 ? Double.random(in: 0...maxStart) : 0

            return VideoClip(
                file: MediaFile(
                    source: entry.source,
                    mediaKind: .video,
                    duration: CMTime(seconds: totalSeconds, preferredTimescale: 600)
                ),
                startTime: CMTime(seconds: startSeconds, preferredTimescale: 600),
                duration: CMTime(seconds: length, preferredTimescale: 600)
            )
        }
    }

    private func validateImageSource(_ entry: SourceEntry, clipLength: Double) -> VideoClip? {
        switch entry.source {
        case .url(let url):
            guard let image = StillImageCache.ciImage(for: url),
                  !image.extent.isEmpty else {
                return nil
            }

            let length = max(clipLength, 0.1)
            return VideoClip(
                file: MediaFile(
                    source: entry.source,
                    mediaKind: .image,
                    duration: CMTime(seconds: length, preferredTimescale: 600)
                ),
                startTime: .zero,
                duration: CMTime(seconds: length, preferredTimescale: 600)
            )

        case .external(let identifier):
            // Verify the asset exists (app-level - uses ApplePhotos directly)
            guard ApplePhotos.shared.fetchAsset(localIdentifier: identifier) != nil else {
                return nil
            }

            let length = max(clipLength, 0.1)
            return VideoClip(
                file: MediaFile(
                    source: entry.source,
                    mediaKind: .image,
                    duration: CMTime(seconds: length, preferredTimescale: 600)
                ),
                startTime: .zero,
                duration: CMTime(seconds: length, preferredTimescale: 600)
            )
        }
    }

    /// Stable key for tracking bad sources
    private func sourceKey(_ source: MediaSource) -> String {
        switch source {
        case .url(let url): return url.path
        case .external(let id): return id
        }
    }

    private func applyExclusions() {
        let hiddenUUIDs = ApplePhotos.shared.cachedHiddenUUIDs
        let excludedPhotoAssetIds: Set<String>

        if ApplePhotos.shared.status.canRead {
            excludedPhotoAssetIds = ApplePhotos.shared.fetchExcludedAssetIdentifiersInHypnographFolder()
        } else {
            excludedPhotoAssetIds = []
        }

        sourceIndex.removeAll { entry in
            // Standard exclusions
            if exclusionStore.isExcluded(entry.source) {
                return true
            }

            // Apple Photos curation albums
            if case .external(let identifier) = entry.source {
                if excludedPhotoAssetIds.contains(identifier) {
                    return true
                }
            }

            // Hidden asset filter: check filename base against cached hidden UUIDs
            if !hiddenUUIDs.isEmpty, case .url(let url) = entry.source {
                let filenameBase = url.deletingPathExtension().lastPathComponent
                if hiddenUUIDs.contains(filenameBase) {
                    return true
                }
            }

            return false
        }
    }

    // MARK: - Exclusions & Deletions (user-driven)

    public func exclude(file: MediaFile) {
        exclusionStore.add(file.source)
        sourceIndex.removeAll { sourceKey($0.source) == sourceKey(file.source) }
    }

    public func removeFromIndex(source: MediaSource) {
        sourceIndex.removeAll { sourceKey($0.source) == sourceKey(source) }
    }
}
