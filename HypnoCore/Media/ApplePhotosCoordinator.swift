import Foundation

// MARK: - Coordinator

/// Shared coordinator for post-Photos-auth library selection.
///
/// Why this exists:
/// - Photos authorization resolves asynchronously.
/// - If an app builds its `MediaLibrary` before auth completes, it can remain empty
///   even after the user grants access, unless something explicitly rebuilds / reselects sources.
/// - Both Hypnograph and Divine previously needed an "if authorized + empty, enable Photos All Items"
///   safeguard. This file centralizes that policy in one place for consistency.
///
/// More proper solution (future refactor):
/// - Defer initial `MediaLibrary` construction until *after* Photos auth resolves,
///   so the app never produces a pre-auth empty library and this fallback can go away.
///   This would involve adding an explicit `start()/reload()` step that both apps call
///   after `ApplePhotos.shared.requestAuthorization()` completes.
public enum ApplePhotosCoordinator {

    /// If Photos is readable and the current library is empty, ensure Photos "All Items" is selected.
    ///
    /// Call this after Photos authorization completes (in your `onPhotosAuthorization` callback or similar).
    /// If the library was built before auth resolved, it may be empty even though Photos has content.
    /// This function detects that scenario and returns updated keys with `photos:all` enabled.
    ///
    /// - Important: This removes any other `photos:*` keys to avoid conflicting album/custom selections,
    ///   then inserts `photos:all`. Folder keys are preserved.
    ///
    /// - Parameters:
    ///   - activeKeys: Current set of active library keys.
    ///   - libraryAssetCount: Number of assets in the current library (0 means empty).
    ///   - photosCanRead: Whether Photos authorization allows reading (`.authorized` or `.limited`).
    ///   - photosAllAssetsCount: Total number of assets in the Photos library.
    ///
    /// - Returns: `(keys: Set<String>, didChange: Bool)` — the updated keys and whether they changed.
    public static func ensurePhotosAllIfAuthorizedAndLibraryEmpty(
        activeKeys: Set<String>,
        libraryAssetCount: Int,
        photosCanRead: Bool,
        photosAllAssetsCount: Int
    ) -> (keys: Set<String>, didChange: Bool) {
        // Only proceed if Photos is readable
        guard photosCanRead else { return (activeKeys, false) }

        // Only proceed if Photos actually has content
        guard photosAllAssetsCount > 0 else { return (activeKeys, false) }

        // Only proceed if the current library is empty
        guard libraryAssetCount == 0 else { return (activeKeys, false) }

        // If already active, nothing to do
        guard !activeKeys.contains(ApplePhotosLibraryKeys.photosAll) else { return (activeKeys, false) }

        // Preserve non-Photos keys, clear other Photos keys, and force photos:all
        var keys = activeKeys.filter { !$0.hasPrefix(ApplePhotosLibraryKeys.photosPrefix) }
        keys.insert(ApplePhotosLibraryKeys.photosAll)

        return (keys, keys != activeKeys)
    }
}
