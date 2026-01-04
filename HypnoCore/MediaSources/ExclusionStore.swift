import Foundation

/// Simple persistent exclusion list for source media.
/// Works with MediaFile.Source to support both file URLs and Photos identifiers.
public final class ExclusionStore {
    public static let shared = ExclusionStore()

    private var excludedIdentifiers: Set<String> = []
    private let queue = DispatchQueue(label: "ExclusionStore.queue")

    private init() {
        load()
    }

    public func isExcluded(_ source: MediaFile.Source) -> Bool {
        queue.sync {
            excludedIdentifiers.contains(identifier(for: source))
        }
    }

    public func add(_ source: MediaFile.Source) {
        queue.sync {
            excludedIdentifiers.insert(identifier(for: source))
            save()
        }
    }

    /// Extract a stable identifier from the source for persistence
    private func identifier(for source: MediaFile.Source) -> String {
        switch source {
        case .url(let url):
            return "file:" + url.standardizedFileURL.path
        case .photos(let id):
            return "photos:" + id
        }
    }

    private func load() {
        let url = HypnoCoreConfig.shared.exclusionsURL
        guard let data = try? Data(contentsOf: url) else { return }
        if let list = try? JSONDecoder().decode([String].self, from: data) {
            excludedIdentifiers = Set(list)
        }
    }

    private func save() {
        let url = HypnoCoreConfig.shared.exclusionsURL
        let list = Array(excludedIdentifiers)
        if let data = try? JSONEncoder().encode(list) {
            try? data.write(to: url)
        }
    }
}
