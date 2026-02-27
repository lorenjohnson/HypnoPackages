import Foundation

public struct HypnoCoreConfig {
    public let appSupportDirectory: URL

    public init(appSupportDirectory: URL) {
        self.appSupportDirectory = appSupportDirectory
    }

    public static var shared = HypnoCoreConfig(appSupportDirectory: defaultAppSupportDirectory)

    public var exclusionsURL: URL {
        appSupportDirectory.appendingPathComponent("exclusions.json")
    }

    public var sourceFavoritesURL: URL {
        appSupportDirectory.appendingPathComponent("source-favorites.json")
    }

    public var applePhotosHiddenIdentifiersCacheURL: URL {
        appSupportDirectory.appendingPathComponent("apple-photos-hidden-local-identifiers.txt")
    }

    public var effectLibrariesDirectory: URL {
        ensureDirectory(appSupportDirectory.appendingPathComponent("effect-libraries", isDirectory: true))
    }

    /// Global RECENT effects store (shared across modes)
    public var recentEffectChainsURL: URL {
        appSupportDirectory.appendingPathComponent("recent-effects.json")
    }

    public var lutsDirectory: URL {
        ensureDirectory(appSupportDirectory.appendingPathComponent("luts", isDirectory: true))
    }

    public var textDirectory: URL {
        ensureDirectory(appSupportDirectory.appendingPathComponent("text", isDirectory: true))
    }

    /// User-editable runtime Metal effect assets.
    /// Each effect lives in runtime-effects/<uuid>/ with effect.json + shader.metal.
    public var runtimeEffectsDirectory: URL {
        ensureDirectory(appSupportDirectory.appendingPathComponent("runtime-effects", isDirectory: true))
    }

    private static var defaultAppSupportDirectory: URL {
        let fm = FileManager.default
        let base = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let bundleSuffix = Bundle.main.bundleIdentifier?.split(separator: ".").last.map(String.init)
        let folderName = bundleSuffix ?? "Hypnograph"
        let appDir = base.appendingPathComponent(folderName, isDirectory: true)

        if !fm.fileExists(atPath: appDir.path) {
            try? fm.createDirectory(at: appDir, withIntermediateDirectories: true, attributes: nil)
        }

        return appDir
    }

    private func ensureDirectory(_ url: URL) -> URL {
        let fm = FileManager.default
        if !fm.fileExists(atPath: url.path) {
            try? fm.createDirectory(at: url, withIntermediateDirectories: true, attributes: nil)
        }
        return url
    }
}
