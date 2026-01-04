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

    public var deletionsURL: URL {
        appSupportDirectory.appendingPathComponent("deletions.json")
    }

    public var favoritesURL: URL {
        appSupportDirectory.appendingPathComponent("favorites.json")
    }

    public var applePhotosHiddenIdentifiersCacheURL: URL {
        appSupportDirectory.appendingPathComponent("apple-photos-hidden-local-identifiers.txt")
    }

    public var effectLibrariesDirectory: URL {
        ensureDirectory(appSupportDirectory.appendingPathComponent("effect-libraries", isDirectory: true))
    }

    public var lutsDirectory: URL {
        ensureDirectory(appSupportDirectory.appendingPathComponent("luts", isDirectory: true))
    }

    public var textDirectory: URL {
        ensureDirectory(appSupportDirectory.appendingPathComponent("text", isDirectory: true))
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
