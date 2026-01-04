//
//  FavoriteStore.swift
//  Hypnograph
//
//  Persistent list of sources the user has marked as favorites.
//

import Foundation

/// Persistent list of favorited sources.
/// Currently informational only - will be used for future features.
public final class FavoriteStore {
    public static let shared = FavoriteStore()

    private var favoritedIdentifiers: Set<String> = []
    private let queue = DispatchQueue(label: "FavoriteStore.queue")

    private init() {
        load()
    }

    /// Check if a source is favorited
    public func isFavorited(_ source: MediaFile.Source) -> Bool {
        queue.sync {
            favoritedIdentifiers.contains(identifier(for: source))
        }
    }

    /// Add a source to favorites
    public func add(_ source: MediaFile.Source) {
        queue.sync {
            favoritedIdentifiers.insert(identifier(for: source))
            save()
        }
    }

    /// Remove a source from favorites
    public func remove(_ source: MediaFile.Source) {
        queue.sync {
            favoritedIdentifiers.remove(identifier(for: source))
            save()
        }
    }

    /// Toggle favorite status, returns new state
    @discardableResult
    public func toggle(_ source: MediaFile.Source) -> Bool {
        queue.sync {
            let id = identifier(for: source)
            if favoritedIdentifiers.contains(id) {
                favoritedIdentifiers.remove(id)
                save()
                return false
            } else {
                favoritedIdentifiers.insert(id)
                save()
                return true
            }
        }
    }

    /// Number of favorites
    public var count: Int {
        queue.sync { favoritedIdentifiers.count }
    }

    // MARK: - Private

    private func identifier(for source: MediaFile.Source) -> String {
        switch source {
        case .url(let url):
            return "file:" + url.standardizedFileURL.path
        case .photos(let id):
            return "photos:" + id
        }
    }

    private func load() {
        let url = HypnoCoreConfig.shared.favoritesURL
        guard let data = try? Data(contentsOf: url) else { return }
        if let list = try? JSONDecoder().decode([String].self, from: data) {
            favoritedIdentifiers = Set(list)
        }
    }

    private func save() {
        let url = HypnoCoreConfig.shared.favoritesURL
        let list = Array(favoritedIdentifiers)
        if let data = try? JSONEncoder().encode(list) {
            try? data.write(to: url)
        }
    }
}
