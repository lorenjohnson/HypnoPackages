//
//  MediaLibraryBuilder.swift
//  HypnoCore
//
//  Protocol and default implementations for building media libraries.
//  Shared by both Hypnograph and Divine apps.
//

import Foundation
import Photos

// MARK: - Settings Protocol

/// Protocol for settings types that provide source library configuration.
/// Both `Settings` and `DivineSettings` conform to this.
public protocol MediaLibrarySettings {
    /// Named folder libraries with expanded paths
    var sourceLibraries: [String: [String]] { get }

    /// Order of library keys for menu display
    var sourceLibraryOrder: [String] { get }

    /// Default library key when none specified
    var defaultSourceLibraryKey: String { get }

    /// Which media types to include
    var sourceMediaTypes: Set<MediaType> { get }
}

// MARK: - Library Builder

/// Builds a `MediaLibrary` from a set of active keys.
/// This logic was duplicated across HypnographState and DivineState.
public enum MediaLibraryBuilder {

    /// Build a library from active keys and settings.
    public static func buildLibrary(
        keys: Set<String>,
        settings: MediaLibrarySettings,
        customPhotosAssetIds: [String],
        exclusionStore: ExclusionStore
    ) -> MediaLibrary {
        var folderPaths: [String] = []
        var photosAlbums: [PHAssetCollection] = []
        var includeAllPhotos = false
        var includeCustomSelection = false

        for key in keys {
            if key == ApplePhotosLibraryKeys.photosAll {
                includeAllPhotos = true
            } else if key == ApplePhotosLibraryKeys.photosCustom {
                includeCustomSelection = true
            } else if key.hasPrefix(ApplePhotosLibraryKeys.photosPrefix) {
                let identifier = String(key.dropFirst(ApplePhotosLibraryKeys.photosPrefix.count))
                if let album = fetchPhotosAlbum(identifier: identifier) {
                    photosAlbums.append(album)
                }
            } else if key == ApplePhotosLibraryKeys.foldersAll {
                for libraryKey in settings.sourceLibraryOrder {
                    if let paths = settings.sourceLibraries[libraryKey] {
                        folderPaths.append(contentsOf: paths)
                    }
                }
            } else {
                if let paths = settings.sourceLibraries[key] {
                    folderPaths.append(contentsOf: paths)
                }
            }
        }

        return MediaLibrary(
            sources: folderPaths,
            photosAlbums: photosAlbums,
            includeAllPhotos: includeAllPhotos,
            customPhotosAssetIds: includeCustomSelection ? customPhotosAssetIds : [],
            allowedMediaTypes: settings.sourceMediaTypes,
            exclusionStore: exclusionStore
        )
    }

    /// Fetch a Photos album by its local identifier.
    public static func fetchPhotosAlbum(identifier: String) -> PHAssetCollection? {
        let albums = PHAssetCollection.fetchAssetCollections(
            withLocalIdentifiers: [identifier],
            options: nil
        )
        return albums.firstObject
    }

    /// Compute updated keys after toggling a library key.
    /// Returns the new set of keys, or nil if no change should occur.
    public static func computeToggledKeys(
        currentKeys: Set<String>,
        toggledKey: String,
        folderLibraryKeys: Set<String>
    ) -> Set<String>? {
        var keys = currentKeys

        if keys.contains(toggledKey) {
            // Removing - ensure at least one library remains
            if keys.count > 1 {
                keys.remove(toggledKey)
            } else {
                return nil // Can't remove the last one
            }
        } else {
            // Adding - handle "All" keys that should deselect others of same type
            if toggledKey == ApplePhotosLibraryKeys.photosAll {
                // Deselect all other Photos albums and custom selection
                keys = keys.filter { !$0.hasPrefix(ApplePhotosLibraryKeys.photosPrefix) }
                keys.remove(ApplePhotosLibraryKeys.photosCustom)
            } else if toggledKey == ApplePhotosLibraryKeys.photosCustom {
                // Custom selection is exclusive - deselect all other Photos sources
                keys = keys.filter { !$0.hasPrefix(ApplePhotosLibraryKeys.photosPrefix) }
                keys.remove(ApplePhotosLibraryKeys.photosAll)
            } else if toggledKey == ApplePhotosLibraryKeys.foldersAll {
                // Deselect all individual folder libraries
                keys = keys.subtracting(folderLibraryKeys)
            } else if toggledKey.hasPrefix(ApplePhotosLibraryKeys.photosPrefix) {
                // Selecting a specific album deselects "All Items" and custom selection
                keys.remove(ApplePhotosLibraryKeys.photosAll)
                keys.remove(ApplePhotosLibraryKeys.photosCustom)
            } else if folderLibraryKeys.contains(toggledKey) {
                // Selecting a specific folder deselects "All Folders"
                keys.remove(ApplePhotosLibraryKeys.foldersAll)
            }
            keys.insert(toggledKey)
        }

        return keys
    }

    /// Build available libraries list for menu display.
    public static func buildAvailableLibraries(
        settings: MediaLibrarySettings,
        customPhotosAssetIds: [String],
        exclusionStore: ExclusionStore
    ) -> [SourceLibraryInfo] {
        var infos: [SourceLibraryInfo] = []
        var folderInfos: [SourceLibraryInfo] = []
        var totalFolderCount = 0

        // Folder-based libraries
        for key in settings.sourceLibraryOrder {
            guard let paths = settings.sourceLibraries[key] else { continue }

            let tempLibrary = MediaLibrary(
                sources: paths,
                allowedMediaTypes: settings.sourceMediaTypes,
                exclusionStore: exclusionStore
            )
            let count = tempLibrary.assetCount

            if count > 0 {
                folderInfos.append(SourceLibraryInfo(
                    id: key,
                    name: key,
                    type: .folders,
                    assetCount: count
                ))
                totalFolderCount += count
            }
        }

        // Add "All Folders" if there are multiple folder libraries
        if folderInfos.count > 1 {
            infos.append(SourceLibraryInfo(
                id: ApplePhotosLibraryKeys.foldersAll,
                name: "All Folders",
                type: .folders,
                assetCount: totalFolderCount
            ))
        }

        infos.append(contentsOf: folderInfos)

        // Apple Photos libraries
        if ApplePhotos.shared.status.canRead {
            let allCount = ApplePhotos.shared.countAllAssets()
            if allCount > 0 {
                infos.append(SourceLibraryInfo(
                    id: ApplePhotosLibraryKeys.photosAll,
                    name: "All Items",
                    type: .applePhotos,
                    assetCount: allCount
                ))
            }

            if !customPhotosAssetIds.isEmpty {
                infos.append(SourceLibraryInfo(
                    id: ApplePhotosLibraryKeys.photosCustom,
                    name: "Custom Selection",
                    type: .applePhotos,
                    assetCount: customPhotosAssetIds.count
                ))
            }

            let userAlbums = ApplePhotos.shared.fetchUserAlbums()
            for album in userAlbums {
                infos.append(SourceLibraryInfo(
                    id: album.libraryKey,
                    name: album.title,
                    type: .applePhotos,
                    assetCount: album.assetCount
                ))
            }
        }

        return infos
    }
}
