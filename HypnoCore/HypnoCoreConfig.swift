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
}
