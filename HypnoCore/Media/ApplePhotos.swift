//
//  ApplePhotos.swift
//  Hypnograph
//
//  Interface to Apple Photos library via PhotoKit.
//  Handles authorization and provides access to PHAssets.
//

import Foundation
import Photos
import AVFoundation

/// Singleton interface to Apple Photos library
public final class ApplePhotos {
    public static let shared = ApplePhotos()

    // MARK: - Authorization

    public enum AuthorizationStatus {
        case notDetermined
        case authorized
        case limited
        case denied
        case restricted

        public var canRead: Bool {
            self == .authorized || self == .limited
        }

        public var canWrite: Bool {
            self == .authorized
        }
    }

    /// Current authorization status (cached, call checkAuthorization() to refresh)
    public private(set) var status: AuthorizationStatus = .notDetermined

    /// In-memory cache of hidden asset UUIDs (loaded from disk on init)
    private(set) var cachedHiddenUUIDs: Set<String> = []

    /// Path to cache file
    private var hiddenIdentifiersCacheURL: URL {
        HypnoCoreConfig.shared.applePhotosHiddenIdentifiersCacheURL
    }

    private init() {
        refreshStatus()
        loadCachedHiddenIdentifiers()
    }

    /// Refresh cached status from system
    public func refreshStatus() {
        let systemStatus = PHPhotoLibrary.authorizationStatus(for: .readWrite)
        status = mapStatus(systemStatus)
    }

    /// Request read/write authorization. Returns the new status.
    @discardableResult
    public func requestAuthorization() async -> AuthorizationStatus {
        let systemStatus = await PHPhotoLibrary.requestAuthorization(for: .readWrite)
        status = mapStatus(systemStatus)
        print("PhotosLibrary: authorization status = \(status)")
        return status
    }

    private func mapStatus(_ systemStatus: PHAuthorizationStatus) -> AuthorizationStatus {
        switch systemStatus {
        case .notDetermined: return .notDetermined
        case .authorized: return .authorized
        case .limited: return .limited
        case .denied: return .denied
        case .restricted: return .restricted
        @unknown default: return .denied
        }
    }

    // MARK: - Hidden Identifiers Cache

    /// Load cached hidden identifiers from disk into memory
    private func loadCachedHiddenIdentifiers() {
        let fm = FileManager.default
        guard fm.fileExists(atPath: hiddenIdentifiersCacheURL.path) else {
            cachedHiddenUUIDs = []
            return
        }

        guard let content = try? String(contentsOf: hiddenIdentifiersCacheURL, encoding: .utf8) else {
            cachedHiddenUUIDs = []
            return
        }

        let lines = content.components(separatedBy: .newlines).filter { !$0.isEmpty }
        cachedHiddenUUIDs = Set(lines)
    }

    /// Refresh hidden identifiers cache from Apple Photos.
    /// Fetches all hidden assets, extracts UUIDs, writes to cache file, updates in-memory cache.
    /// Returns count of hidden assets found.
    @discardableResult
    public func refreshHiddenIdentifiersCache() -> Int {
        guard status.canRead else { return 0 }

        let assets = fetchHiddenAssets()
        var uuids = Set<String>()

        for asset in assets {
            let identifier = asset.localIdentifier
            if let slashIndex = identifier.firstIndex(of: "/") {
                let uuid = String(identifier[..<slashIndex])
                uuids.insert(uuid)
            } else {
                uuids.insert(identifier)
            }
        }

        // Write to file
        let fm = FileManager.default
        let dir = hiddenIdentifiersCacheURL.deletingLastPathComponent()
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)

        let content = uuids.sorted().joined(separator: "\n")
        try? content.write(to: hiddenIdentifiersCacheURL, atomically: true, encoding: .utf8)

        cachedHiddenUUIDs = uuids
        return assets.count
    }

    /// Check if a filename (without extension) matches any cached hidden asset UUID
    public func isHiddenAsset(filenameBase: String) -> Bool {
        cachedHiddenUUIDs.contains(filenameBase)
    }

    // MARK: - Fetching Assets

    /// Fetch video assets from Photos library
    public func fetchVideos(limit: Int? = nil) -> [PHAsset] {
        guard status.canRead else { return [] }

        let options = PHFetchOptions()
        options.predicate = NSPredicate(format: "mediaType == %d", PHAssetMediaType.video.rawValue)
        options.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: false)]
        if let limit = limit {
            options.fetchLimit = limit
        }

        let results = PHAsset.fetchAssets(with: options)
        return results.objects(at: IndexSet(integersIn: 0..<results.count))
    }

    /// Fetch image assets from Photos library
    public func fetchImages(limit: Int? = nil) -> [PHAsset] {
        guard status.canRead else { return [] }

        let options = PHFetchOptions()
        options.predicate = NSPredicate(format: "mediaType == %d", PHAssetMediaType.image.rawValue)
        options.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: false)]
        if let limit = limit {
            options.fetchLimit = limit
        }

        let results = PHAsset.fetchAssets(with: options)
        return results.objects(at: IndexSet(integersIn: 0..<results.count))
    }

    /// Fetch a specific asset by local identifier
    public func fetchAsset(localIdentifier: String) -> PHAsset? {
        let results = PHAsset.fetchAssets(withLocalIdentifiers: [localIdentifier], options: nil)
        return results.firstObject
    }

    /// Fetch all assets from the entire Photos library (photos and videos)
    public func fetchAllAssets(limit: Int? = nil) -> [PHAsset] {
        guard status.canRead else { return [] }

        let options = PHFetchOptions()
        options.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: false)]
        if let limit = limit {
            options.fetchLimit = limit
        }

        let results = PHAsset.fetchAssets(with: options)
        return results.objects(at: IndexSet(integersIn: 0..<results.count))
    }

    /// Count all assets in the entire Photos library
    public func countAllAssets() -> Int {
        guard status.canRead else { return 0 }
        return PHAsset.fetchAssets(with: nil).count
    }

    // MARK: - Album Discovery

    /// Album info for menu display
    public struct AlbumInfo {
        public let localIdentifier: String
        public let title: String
        public let assetCount: Int

        /// Key for use in library selection (consistent with existing convention)
        public var libraryKey: String {
            "photos:\(localIdentifier)"
        }
    }

    /// Fetch all user-created albums (not smart albums)
    /// Returns array of AlbumInfo sorted alphabetically by title
    public func fetchUserAlbums() -> [AlbumInfo] {
        guard status.canRead else { return [] }

        var albums: [AlbumInfo] = []

        // Fetch all user-created albums
        let userAlbums = PHAssetCollection.fetchAssetCollections(
            with: .album,
            subtype: .albumRegular,
            options: nil
        )

        for i in 0..<userAlbums.count {
            let album = userAlbums.object(at: i)
            let assetCount = PHAsset.fetchAssets(in: album, options: nil).count

            // Only include non-empty albums
            if assetCount > 0, let title = album.localizedTitle {
                albums.append(AlbumInfo(
                    localIdentifier: album.localIdentifier,
                    title: title,
                    assetCount: assetCount
                ))
            }
        }

        // Sort alphabetically by title
        return albums.sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
    }

    /// Fetch an album by local identifier
    public func fetchAlbum(localIdentifier: String) -> PHAssetCollection? {
        let result = PHAssetCollection.fetchAssetCollections(
            withLocalIdentifiers: [localIdentifier],
            options: nil
        )
        return result.firstObject
    }

    // MARK: - AVAsset Loading

    /// Request AVAsset for a PHAsset (video)
    public func requestAVAsset(for asset: PHAsset) async -> AVAsset? {
        guard status.canRead else { return nil }
        guard asset.mediaType == .video else { return nil }

        return await withCheckedContinuation { continuation in
            let options = PHVideoRequestOptions()
            options.version = .current
            options.deliveryMode = .highQualityFormat
            options.isNetworkAccessAllowed = true

            PHImageManager.default().requestAVAsset(forVideo: asset, options: options) { avAsset, _, _ in
                continuation.resume(returning: avAsset)
            }
        }
    }

    // MARK: - Image Loading

    /// Request CIImage for a PHAsset (image)
    public func requestCIImage(for asset: PHAsset) async -> CIImage? {
        guard status.canRead else { return nil }
        guard asset.mediaType == .image else { return nil }

        return await withCheckedContinuation { continuation in
            let options = PHImageRequestOptions()
            options.version = .current
            options.deliveryMode = .highQualityFormat
            options.isNetworkAccessAllowed = true
            options.isSynchronous = false

            // Request full-size image data
            PHImageManager.default().requestImageDataAndOrientation(for: asset, options: options) { data, _, orientation, _ in
                guard let data = data else {
                    continuation.resume(returning: nil)
                    return
                }

                // Create CIImage from data
                guard let ciImage = CIImage(data: data) else {
                    continuation.resume(returning: nil)
                    return
                }

                // Apply orientation correction using CGImagePropertyOrientation
                let oriented = ciImage.oriented(orientation)
                continuation.resume(returning: oriented)
            }
        }
    }

    // MARK: - Hidden Assets

    /// Fetch all hidden assets from Photos library
    /// Returns array of PHAssets from the Hidden album
    /// Note: Requires "Use Touch ID for Hidden Album" to be disabled in Photos settings
    public func fetchHiddenAssets() -> [PHAsset] {
        guard status.canRead else { return [] }

        // Fetch the Hidden smart album
        let hiddenAlbums = PHAssetCollection.fetchAssetCollections(
            with: .smartAlbum,
            subtype: .smartAlbumAllHidden,
            options: nil
        )

        guard let hiddenAlbum = hiddenAlbums.firstObject else {
            print("PhotosLibrary: Hidden album not found")
            return []
        }

        // Must explicitly include hidden assets - this is off by default
        let fetchOptions = PHFetchOptions()
        fetchOptions.includeHiddenAssets = true

        let hiddenAssets = PHAsset.fetchAssets(in: hiddenAlbum, options: fetchOptions)

        if hiddenAssets.count == 0 && hiddenAlbum.estimatedAssetCount == NSNotFound {
            print("PhotosLibrary: Hidden album protected - disable Touch ID in Photos settings to access")
        }

        return hiddenAssets.objects(at: IndexSet(integersIn: 0..<hiddenAssets.count))
    }

    // MARK: - Debug / Inspection

    /// Log detailed info about a specific asset by local identifier (or UUID prefix)
    public func logAssetInfo(identifier: String) {
        // Try exact match first
        var asset = fetchAsset(localIdentifier: identifier)

        // If not found, try as UUID prefix (search all assets)
        if asset == nil {
            print("PhotosLibrary: No exact match for '\(identifier)', searching by UUID prefix...")
            let options = PHFetchOptions()
            options.predicate = NSPredicate(format: "localIdentifier BEGINSWITH %@", identifier)
            let results = PHAsset.fetchAssets(with: options)
            asset = results.firstObject
        }

        guard let asset = asset else {
            print("PhotosLibrary: Asset not found for identifier '\(identifier)'")
            return
        }

        print("=== Asset Info: \(identifier) ===")
        print("  Local Identifier: \(asset.localIdentifier)")
        print("  Media Type: \(asset.mediaType == .image ? "image" : asset.mediaType == .video ? "video" : "other")")
        print("  Media Subtypes: \(asset.mediaSubtypes.rawValue)")
        print("  Creation Date: \(asset.creationDate?.description ?? "nil")")
        print("  Modification Date: \(asset.modificationDate?.description ?? "nil")")
        print("  Duration: \(asset.duration) seconds")
        print("  Pixel Width: \(asset.pixelWidth)")
        print("  Pixel Height: \(asset.pixelHeight)")
        print("  Is Favorite: \(asset.isFavorite)")
        print("  Is Hidden: \(asset.isHidden)")
        print("  Source Type: \(asset.sourceType.rawValue)")

        // Get resource info (file paths, etc)
        let resources = PHAssetResource.assetResources(for: asset)
        print("  Resources (\(resources.count)):")
        for (idx, resource) in resources.enumerated() {
            print("    [\(idx)] type=\(resource.type.rawValue) filename=\(resource.originalFilename) uti=\(resource.uniformTypeIdentifier)")
        }
        print("===================================")
    }

    /// Set favorite status for an asset
    public func setFavorite(_ asset: PHAsset, isFavorite: Bool) async -> Bool {
        guard status.canWrite else { return false }

        do {
            try await PHPhotoLibrary.shared().performChanges {
                let request = PHAssetChangeRequest(for: asset)
                request.isFavorite = isFavorite
            }
            return true
        } catch {
            print("PhotosLibrary: failed to set favorite - \(error)")
            return false
        }
    }

    // MARK: - Album Management

    /// Folder name for Hypnogram-related albums (curation workflow)
    private static let hypnogramsFolderName = "Hypnograph"

    /// Album name for saved hypnograms (snapshots and renders)
    private static let hypnogramsAlbumName = "Saved"

    /// Album name for sources excluded from random selection (curation workflow)
    private static let excludedAlbumName = "Excluded"

    /// Album name for sources marked as favorites (curation workflow)
    private static let favoritesAlbumName = "Favorites"

    /// Find an existing top-level album by name
    private func findAlbum(named name: String) -> PHAssetCollection? {
        let options = PHFetchOptions()
        options.predicate = NSPredicate(format: "title == %@", name)
        let albums = PHAssetCollection.fetchAssetCollections(with: .album, subtype: .albumRegular, options: options)
        return albums.firstObject
    }

    private func findFolder(named name: String) -> PHCollectionList? {
        let options = PHFetchOptions()
        options.predicate = NSPredicate(format: "title == %@", name)
        let folders = PHCollectionList.fetchCollectionLists(with: .folder, subtype: .any, options: options)
        return folders.firstObject
    }

    private func findAlbum(named albumName: String, inFolderNamed folderName: String) -> PHAssetCollection? {
        guard let folder = findFolder(named: folderName) else { return nil }
        let children = PHCollection.fetchCollections(in: folder, options: nil)
        for idx in 0..<children.count {
            guard let album = children.object(at: idx) as? PHAssetCollection else { continue }
            if album.localizedTitle == albumName {
                return album
            }
        }
        return nil
    }

    private func findOrCreateAlbum(named name: String) async -> PHAssetCollection? {
        if let existing = findAlbum(named: name) {
            return existing
        }

        guard status.canWrite else {
            print("ApplePhotos: cannot create album - no write access")
            return nil
        }

        var albumPlaceholderID: String?
        do {
            try await PHPhotoLibrary.shared().performChanges {
                let request = PHAssetCollectionChangeRequest.creationRequestForAssetCollection(withTitle: name)
                albumPlaceholderID = request.placeholderForCreatedAssetCollection.localIdentifier
            }
        } catch {
            print("ApplePhotos: failed to create album '\(name)' - \(error)")
            return nil
        }

        guard let id = albumPlaceholderID else { return nil }
        let result = PHAssetCollection.fetchAssetCollections(withLocalIdentifiers: [id], options: nil)
        return result.firstObject
    }

    private func findOrCreateFolder(named name: String) async -> PHCollectionList? {
        if let existing = findFolder(named: name) {
            return existing
        }

        guard status.canWrite else {
            print("ApplePhotos: cannot create folder - no write access")
            return nil
        }

        var placeholderID: String?
        do {
            try await PHPhotoLibrary.shared().performChanges {
                let request = PHCollectionListChangeRequest.creationRequestForCollectionList(withTitle: name)
                placeholderID = request.placeholderForCreatedCollectionList.localIdentifier
            }
        } catch {
            print("ApplePhotos: failed to create folder '\(name)' - \(error)")
            return nil
        }

        guard let id = placeholderID else { return nil }
        let result = PHCollectionList.fetchCollectionLists(withLocalIdentifiers: [id], options: nil)
        return result.firstObject
    }

    private func ensureAlbum(_ album: PHAssetCollection, isInFolder folder: PHCollectionList) async {
        let children = PHCollection.fetchCollections(in: folder, options: nil)
        for idx in 0..<children.count {
            if let child = children.object(at: idx) as? PHAssetCollection,
               child.localIdentifier == album.localIdentifier {
                return
            }
        }

        do {
            try await PHPhotoLibrary.shared().performChanges {
                guard let folderRequest = PHCollectionListChangeRequest(for: folder) else { return }
                folderRequest.addChildCollections([album] as NSArray)
            }
            print("ApplePhotos: added album '\(album.localizedTitle ?? "(untitled)")' to folder '\(folder.localizedTitle ?? "(untitled)")'")
        } catch {
            print("ApplePhotos: failed to add album to folder - \(error)")
        }
    }

    private func findOrCreateAlbum(named albumName: String, inFolderNamed folderName: String) async -> PHAssetCollection? {
        guard let folder = await findOrCreateFolder(named: folderName) else { return nil }

        let album = await findOrCreateAlbum(named: albumName)
        guard let album else { return nil }

        await ensureAlbum(album, isInFolder: folder)
        return album
    }

    private func fetchAssetIdentifiers(inAlbumNamed albumName: String, inFolderNamed folderName: String) -> Set<String> {
        refreshStatus()
        guard status.canRead else { return [] }

        let album = findAlbum(named: albumName, inFolderNamed: folderName) ?? findAlbum(named: albumName)
        guard let album else { return [] }

        let assets = PHAsset.fetchAssets(in: album, options: nil)
        var identifiers = Set<String>()
        identifiers.reserveCapacity(assets.count)

        for i in 0..<assets.count {
            identifiers.insert(assets.object(at: i).localIdentifier)
        }
        return identifiers
    }

    /// Find or create the Hypnograms album (top-level, not in a folder)
    public func findOrCreateHypnogramsAlbum() async -> PHAssetCollection? {
        refreshStatus()
        return await findOrCreateAlbum(named: Self.hypnogramsAlbumName, inFolderNamed: Self.hypnogramsFolderName)
    }

    public func fetchExcludedAssetIdentifiersInHypnographFolder() -> Set<String> {
        fetchAssetIdentifiers(inAlbumNamed: Self.excludedAlbumName, inFolderNamed: Self.hypnogramsFolderName)
    }

    public func addAssetToExcludedAlbumInHypnographFolder(localIdentifier: String) async -> Bool {
        refreshStatus()
        return await addAsset(localIdentifier: localIdentifier, toAlbumNamed: Self.excludedAlbumName, inFolderNamed: Self.hypnogramsFolderName)
    }

    public func addAssetToFavoritesAlbumInHypnographFolder(localIdentifier: String) async -> Bool {
        refreshStatus()
        return await addAsset(localIdentifier: localIdentifier, toAlbumNamed: Self.favoritesAlbumName, inFolderNamed: Self.hypnogramsFolderName)
    }

    private func resolveAsset(identifier: String) -> PHAsset? {
        if let exact = fetchAsset(localIdentifier: identifier) {
            return exact
        }
        let options = PHFetchOptions()
        options.predicate = NSPredicate(format: "localIdentifier BEGINSWITH %@", identifier)
        let results = PHAsset.fetchAssets(with: options)
        return results.firstObject
    }

    /// Add an existing Photos asset to a named album (creating it if needed).
    public func addAsset(localIdentifier: String, toAlbumNamed albumName: String, inFolderNamed folderName: String? = nil) async -> Bool {
        refreshStatus()
        guard status.canWrite else {
            print("ApplePhotos: cannot add asset to album - no write access")
            return false
        }

        guard let asset = resolveAsset(identifier: localIdentifier) else {
            print("ApplePhotos: cannot add asset to album - asset not found (\(localIdentifier))")
            return false
        }

        let album: PHAssetCollection?
        if let folderName {
            album = await findOrCreateAlbum(named: albumName, inFolderNamed: folderName)
        } else {
            album = await findOrCreateAlbum(named: albumName)
        }

        guard let album else {
            print("ApplePhotos: cannot add asset to album - failed to get/create album '\(albumName)'")
            return false
        }

        do {
            try await PHPhotoLibrary.shared().performChanges {
                guard let albumRequest = PHAssetCollectionChangeRequest(for: album) else { return }
                albumRequest.addAssets([asset] as NSArray)
            }
            print("ApplePhotos: added existing asset to '\(albumName)' album")
            return true
        } catch {
            print("ApplePhotos: failed to add existing asset to album '\(albumName)' - \(error)")
            return false
        }
    }

    /// Fetch assets from an album
    public func fetchAssets(from album: PHAssetCollection, limit: Int? = nil) -> [PHAsset] {
        let options = PHFetchOptions()
        options.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: false)]
        if let limit = limit {
            options.fetchLimit = limit
        }

        let results = PHAsset.fetchAssets(in: album, options: options)
        return results.objects(at: IndexSet(integersIn: 0..<results.count))
    }

    // MARK: - Saving to Photos

    /// Save an image file to Photos and add to the Hypnograms album
    public func saveImage(at url: URL) async -> Bool {
        await saveImage(at: url, toAlbumNamed: Self.hypnogramsAlbumName, inFolderNamed: Self.hypnogramsFolderName)
    }

    /// Save a video file to Photos and add to the Hypnograms album
    public func saveVideo(at url: URL) async -> Bool {
        await saveVideo(at: url, toAlbumNamed: Self.hypnogramsAlbumName, inFolderNamed: Self.hypnogramsFolderName)
    }

    /// Save an image file to Photos and add to a specific album (optionally inside a folder).
    public func saveImage(at url: URL, toAlbumNamed albumName: String, inFolderNamed folderName: String? = nil) async -> Bool {
        refreshStatus()
        guard status.canWrite else {
            print("ApplePhotos: cannot save image - no write access")
            return false
        }

        let album: PHAssetCollection?
        if let folderName {
            album = await findOrCreateAlbum(named: albumName, inFolderNamed: folderName)
        } else {
            album = await findOrCreateAlbum(named: albumName)
        }

        guard let album else {
            print("ApplePhotos: cannot save image - failed to get/create album '\(albumName)'")
            return false
        }

        var assetPlaceholder: PHObjectPlaceholder?

        do {
            try await PHPhotoLibrary.shared().performChanges {
                let request = PHAssetChangeRequest.creationRequestForAssetFromImage(atFileURL: url)
                assetPlaceholder = request?.placeholderForCreatedAsset
            }
        } catch {
            print("ApplePhotos: failed to create image asset - \(error)")
            return false
        }

        guard let placeholder = assetPlaceholder else { return false }

        do {
            try await PHPhotoLibrary.shared().performChanges {
                guard let albumRequest = PHAssetCollectionChangeRequest(for: album) else { return }
                albumRequest.addAssets([placeholder] as NSArray)
            }
            print("ApplePhotos: saved image to '\(albumName)' album")
            return true
        } catch {
            print("ApplePhotos: failed to add image to album '\(albumName)' - \(error)")
            return false
        }
    }

    /// Save a video file to Photos and add to a specific album (optionally inside a folder).
    public func saveVideo(at url: URL, toAlbumNamed albumName: String, inFolderNamed folderName: String? = nil) async -> Bool {
        refreshStatus()
        guard status.canWrite else {
            print("ApplePhotos: cannot save video - no write access")
            return false
        }

        let album: PHAssetCollection?
        if let folderName {
            album = await findOrCreateAlbum(named: albumName, inFolderNamed: folderName)
        } else {
            album = await findOrCreateAlbum(named: albumName)
        }

        guard let album else {
            print("ApplePhotos: cannot save video - failed to get/create album '\(albumName)'")
            return false
        }

        var assetPlaceholder: PHObjectPlaceholder?

        do {
            try await PHPhotoLibrary.shared().performChanges {
                let request = PHAssetChangeRequest.creationRequestForAssetFromVideo(atFileURL: url)
                assetPlaceholder = request?.placeholderForCreatedAsset
            }
        } catch {
            print("ApplePhotos: failed to create video asset - \(error)")
            return false
        }

        guard let placeholder = assetPlaceholder else { return false }

        do {
            try await PHPhotoLibrary.shared().performChanges {
                guard let albumRequest = PHAssetCollectionChangeRequest(for: album) else { return }
                albumRequest.addAssets([placeholder] as NSArray)
            }
            print("ApplePhotos: saved video to '\(albumName)' album")
            return true
        } catch {
            print("ApplePhotos: failed to add video to album '\(albumName)' - \(error)")
            return false
        }
    }
}
