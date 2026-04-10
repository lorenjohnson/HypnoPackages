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
    private let excludeHypnographCurationAssets: Bool

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
        exclusionStore: ExclusionStore,
        excludeHypnographCurationAssets: Bool = true
    ) {
        self.allowedMediaTypes = allowedMediaTypes
        self.exclusionStore = exclusionStore
        self.excludeHypnographCurationAssets = excludeHypnographCurationAssets
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
        exclusionStore: ExclusionStore,
        excludeHypnographCurationAssets: Bool = true
    ) {
        self.allowedMediaTypes = allowedMediaTypes
        self.exclusionStore = exclusionStore
        self.excludeHypnographCurationAssets = excludeHypnographCurationAssets
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
        exclusionStore: ExclusionStore,
        excludeHypnographCurationAssets: Bool = true
    ) {
        self.allowedMediaTypes = allowedMediaTypes
        self.exclusionStore = exclusionStore
        self.excludeHypnographCurationAssets = excludeHypnographCurationAssets

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

        var results: [SourceEntry] = []
        var resolved = 0
        var unresolved: [String] = []

        // Resolve one-by-one so we can preserve caller-provided ordering and
        // handle mixed identifier formats more robustly.
        for identifier in identifiers {
            guard let asset = ApplePhotos.shared.resolveAsset(localIdentifierLike: identifier) else {
                unresolved.append(identifier)
                continue
            }
            resolved += 1

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
        print(
            "MediaLibrary: indexed \(results.count) assets from custom selection " +
            "(\(resolved)/\(identifiers.count) identifiers resolved)"
        )
        if !unresolved.isEmpty {
            let preview = unresolved.prefix(5).joined(separator: ", ")
            print(
                "MediaLibrary: unresolved custom IDs (\(unresolved.count)): " +
                "\(preview)\(unresolved.count > 5 ? ", ..." : "")"
            )
        }
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
        var seenPaths = Set<String>()

        for rawSource in sources {
            let source = (rawSource as NSString).expandingTildeInPath

            if containsGlobToken(source) {
                let recurse = source.contains("**")
                let matches = expandGlobPattern(source, fileManager: fileManager)

                for match in matches {
                    var isDirectory: ObjCBool = false
                    guard fileManager.fileExists(atPath: match.path, isDirectory: &isDirectory) else { continue }

                    if isDirectory.boolValue {
                        collectMedia(
                            from: match,
                            recursive: recurse,
                            fileManager: fileManager,
                            results: &results,
                            seenPaths: &seenPaths
                        )
                    } else {
                        appendIfSupportedMediaFile(
                            match,
                            fileManager: fileManager,
                            results: &results,
                            seenPaths: &seenPaths
                        )
                    }
                }
            } else {
                let url = URL(fileURLWithPath: source)
                var isDirectory: ObjCBool = false
                guard fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory) else { continue }

                if isDirectory.boolValue {
                    collectMedia(
                        from: url,
                        recursive: false,
                        fileManager: fileManager,
                        results: &results,
                        seenPaths: &seenPaths
                    )
                } else {
                    appendIfSupportedMediaFile(
                        url,
                        fileManager: fileManager,
                        results: &results,
                        seenPaths: &seenPaths
                    )
                }
            }
        }

        self.sourceIndex.append(contentsOf: results)
    }

    private func collectMedia(
        from directoryURL: URL,
        recursive: Bool,
        fileManager: FileManager,
        results: inout [SourceEntry],
        seenPaths: inout Set<String>
    ) {
        if recursive {
            guard let enumerator = fileManager.enumerator(
                at: directoryURL,
                includingPropertiesForKeys: nil
            ) else { return }

            for case let fileURL as URL in enumerator {
                appendIfSupportedMediaFile(
                    fileURL,
                    fileManager: fileManager,
                    results: &results,
                    seenPaths: &seenPaths
                )
            }
            return
        }

        guard let contents = try? fileManager.contentsOfDirectory(
            at: directoryURL,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) else {
            return
        }

        for fileURL in contents {
            appendIfSupportedMediaFile(
                fileURL,
                fileManager: fileManager,
                results: &results,
                seenPaths: &seenPaths
            )
        }
    }

    private func appendIfSupportedMediaFile(
        _ fileURL: URL,
        fileManager: FileManager,
        results: inout [SourceEntry],
        seenPaths: inout Set<String>
    ) {
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: fileURL.path, isDirectory: &isDirectory),
              !isDirectory.boolValue else {
            return
        }

        let normalizedPath = fileURL.standardizedFileURL.path
        guard seenPaths.insert(normalizedPath).inserted else { return }

        let ext = fileURL.pathExtension.lowercased()
        if allowVideos && allowVideoExtensions.contains(ext) {
            results.append(SourceEntry(source: .url(fileURL), mediaKind: .video))
        } else if allowImages && allowedPhotoExtensions.contains(ext) {
            results.append(SourceEntry(source: .url(fileURL), mediaKind: .image))
        }
    }

    private func containsGlobToken(_ value: String) -> Bool {
        value.contains("*") || value.contains("?")
    }

    private func expandGlobPattern(_ pattern: String, fileManager: FileManager) -> [URL] {
        let (baseURL, globPattern) = splitGlobPattern(pattern)
        guard fileManager.fileExists(atPath: baseURL.path) else { return [] }

        let regexPattern = globToRegex(globPattern)
        guard let regex = try? NSRegularExpression(pattern: regexPattern) else { return [] }

        var candidates: [URL] = [baseURL]
        if let enumerator = fileManager.enumerator(
            at: baseURL,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) {
            for case let fileURL as URL in enumerator {
                candidates.append(fileURL)
            }
        }

        var results: [URL] = []
        for candidate in candidates {
            let relPath = relativePath(candidate, from: baseURL)
            let nsRelPath = relPath as NSString
            let fullRange = NSRange(location: 0, length: nsRelPath.length)
            let match = regex.firstMatch(in: relPath, range: fullRange)
            if match?.range == fullRange {
                results.append(candidate)
            }
        }
        return results
    }

    private func splitGlobPattern(_ pattern: String) -> (baseURL: URL, globPattern: String) {
        guard let firstGlobIndex = pattern.firstIndex(where: { $0 == "*" || $0 == "?" }) else {
            return (URL(fileURLWithPath: pattern), "")
        }

        let prefix = String(pattern[..<firstGlobIndex])
        let slashIndex = prefix.lastIndex(of: "/")

        let basePath: String
        let globPattern: String

        if let slashIndex {
            if slashIndex == pattern.startIndex {
                basePath = "/"
            } else {
                basePath = String(pattern[..<slashIndex])
            }
            let patternStart = pattern.index(after: slashIndex)
            globPattern = String(pattern[patternStart...])
        } else {
            basePath = "."
            globPattern = pattern
        }

        return (URL(fileURLWithPath: basePath), globPattern)
    }

    private func relativePath(_ url: URL, from baseURL: URL) -> String {
        let basePath = baseURL.standardizedFileURL.path
        let candidatePath = url.standardizedFileURL.path

        if candidatePath == basePath { return "" }
        let prefix = basePath.hasSuffix("/") ? basePath : basePath + "/"
        if candidatePath.hasPrefix(prefix) {
            return String(candidatePath.dropFirst(prefix.count))
        }
        return candidatePath
    }

    private func globToRegex(_ glob: String) -> String {
        let chars = Array(glob)
        var regex = "^"
        var index = 0

        while index < chars.count {
            let ch = chars[index]

            if ch == "*" {
                if index + 1 < chars.count, chars[index + 1] == "*" {
                    if index + 2 < chars.count, chars[index + 2] == "/" {
                        // **/ matches zero or more path components.
                        regex += "(?:[^/]+/)*"
                        index += 3
                    } else {
                        regex += ".*"
                        index += 2
                    }
                } else {
                    regex += "[^/]*"
                    index += 1
                }
                continue
            }

            if ch == "?" {
                regex += "[^/]"
                index += 1
                continue
            }

            if "\\.^$+()[]{}|".contains(ch) {
                regex += "\\"
            }
            regex.append(ch)
            index += 1
        }

        regex += "$"
        return regex
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
    /// When `excludingSourceIdentifiers` is provided, any matching source is skipped.
    public func randomClip(
        excludingSourceIdentifiers: Set<String> = [],
        clipLength: Double? = nil,
        imageDuration: Double = 0.1
    ) -> MediaClip? {
        // Consider all sources except known-bad entries and explicit exclusions.
        let candidates = sourceIndex.filter { entry in
            let key = sourceKey(entry.source)
            return !badSources.contains(key) && !excludingSourceIdentifiers.contains(key)
        }
        guard !candidates.isEmpty else {
            print(
                "⚠️ MediaLibrary.randomClip: No candidates (sourceIndex: \(sourceIndex.count), " +
                "badSources: \(badSources.count), excluded: \(excludingSourceIdentifiers.count))"
            )
            return nil
        }

        // Shuffle once and walk the full candidate set so we do not fail early when
        // the deck is nearly exhausted. When a preferred clip length is provided,
        // first bias toward sources that can satisfy that requested duration in full.
        let shuffledCandidates = candidates.shuffled()

        if let clipLength {
            for entry in shuffledCandidates {
                let key = sourceKey(entry.source)

                switch entry.mediaKind {
                case .video:
                    switch validateVideoSource(entry, clipLength: clipLength, requireRequestedLength: true) {
                    case .success(let clip):
                        return clip
                    case .sourceInvalid:
                        badSources.insert(key)
                    case .requestedLengthUnavailable:
                        continue
                    }

                case .image:
                    let effectiveLength = clipLength
                    guard let clip = validateImageSource(entry, clipLength: effectiveLength) else {
                        badSources.insert(key)
                        continue
                    }
                    return clip
                }
            }
        }

        for entry in shuffledCandidates {
            let key = sourceKey(entry.source)

            switch entry.mediaKind {
            case .video:
                switch validateVideoSource(entry, clipLength: clipLength, requireRequestedLength: false) {
                case .success(let clip):
                    return clip
                case .sourceInvalid, .requestedLengthUnavailable:
                    badSources.insert(key)
                    continue
                }

            case .image:
                let effectiveLength = clipLength ?? imageDuration
                guard let clip = validateImageSource(entry, clipLength: effectiveLength) else {
                    badSources.insert(key)
                    continue
                }
                return clip
            }
        }

        return nil
    }

    // MARK: - Source Validation

    private enum VideoClipValidationResult {
        case success(MediaClip)
        case requestedLengthUnavailable
        case sourceInvalid
    }

    private func validateVideoSource(
        _ entry: SourceEntry,
        clipLength: Double?,
        requireRequestedLength: Bool
    ) -> VideoClipValidationResult {
        switch entry.source {
        case .url(let url):
            let asset = AVURLAsset(url: url)
            let totalSeconds = asset.duration.seconds

            guard totalSeconds > 0,
                  asset.isPlayable,
                  asset.tracks(withMediaType: .video).first != nil else {
                return .sourceInvalid
            }

            if requireRequestedLength, let clipLength, totalSeconds < clipLength {
                return .requestedLengthUnavailable
            }

            let length = clipLength.map { min($0, totalSeconds) } ?? totalSeconds
            let maxStart = max(0.0, totalSeconds - length)
            let startSeconds = maxStart > 0 ? Double.random(in: 0...maxStart) : 0

            return .success(MediaClip(
                file: MediaFile(
                    source: entry.source,
                    mediaKind: .video,
                    duration: CMTime(seconds: totalSeconds, preferredTimescale: 600)
                ),
                startTime: CMTime(seconds: startSeconds, preferredTimescale: 600),
                duration: CMTime(seconds: length, preferredTimescale: 600)
            ))

        case .external(let identifier):
            // Fetch PHAsset to get duration (app-level - uses ApplePhotos directly)
            guard let phAsset = ApplePhotos.shared.fetchAsset(localIdentifier: identifier) else {
                return .sourceInvalid
            }

            let totalSeconds = phAsset.duration
            guard totalSeconds > 0 else { return .sourceInvalid }

            if requireRequestedLength, let clipLength, totalSeconds < clipLength {
                return .requestedLengthUnavailable
            }

            let length = clipLength.map { min($0, totalSeconds) } ?? totalSeconds
            let maxStart = max(0.0, totalSeconds - length)
            let startSeconds = maxStart > 0 ? Double.random(in: 0...maxStart) : 0

            return .success(MediaClip(
                file: MediaFile(
                    source: entry.source,
                    mediaKind: .video,
                    duration: CMTime(seconds: totalSeconds, preferredTimescale: 600)
                ),
                startTime: CMTime(seconds: startSeconds, preferredTimescale: 600),
                duration: CMTime(seconds: length, preferredTimescale: 600)
            ))
        }
    }

    private func validateImageSource(_ entry: SourceEntry, clipLength: Double) -> MediaClip? {
        switch entry.source {
        case .url(let url):
            guard let image = StillImageCache.ciImage(for: url),
                  !image.extent.isEmpty else {
                return nil
            }

            let length = max(clipLength, 0.1)
            return MediaClip(
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
            return MediaClip(
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

        if excludeHypnographCurationAssets, ApplePhotos.shared.status.canRead {
            excludedPhotoAssetIds = ApplePhotos.shared.fetchExcludedAssetIdentifiersInHypnographFolder()
        } else {
            excludedPhotoAssetIds = []
        }

        let beforeCount = sourceIndex.count
        var removedByExclusionStore = 0
        var removedByCurationAlbum = 0
        var removedByHiddenFilter = 0

        sourceIndex.removeAll { entry in
            if exclusionStore.isExcluded(entry.source) {
                removedByExclusionStore += 1
                return true
            }

            if case .external(let identifier) = entry.source,
               excludedPhotoAssetIds.contains(identifier) {
                removedByCurationAlbum += 1
                return true
            }

            if !hiddenUUIDs.isEmpty, case .url(let url) = entry.source {
                let filenameBase = url.deletingPathExtension().lastPathComponent
                if hiddenUUIDs.contains(filenameBase) {
                    removedByHiddenFilter += 1
                    return true
                }
            }

            return false
        }

        let removedTotal = removedByExclusionStore + removedByCurationAlbum + removedByHiddenFilter
        if removedTotal > 0 {
            print(
                "MediaLibrary: applyExclusions removed \(removedTotal) of \(beforeCount) " +
                "[store: \(removedByExclusionStore), curation: \(removedByCurationAlbum), hidden: \(removedByHiddenFilter)]"
            )
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
