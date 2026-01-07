//
//  PersistentIdentifierStore.swift
//  HypnoCore
//
//  Generic thread-safe persistent store for tracking media sources by identifier.
//  Base functionality for ExclusionStore and DeleteStore.
//

import Foundation

/// Thread-safe persistent store for media source identifiers.
/// Stores identifiers derived from `MediaSource` as strings.
public class PersistentIdentifierStore {
    private var identifiers: Set<String> = []
    private let queue: DispatchQueue
    private let storeURL: URL

    public init(url: URL, queueLabel: String) {
        self.storeURL = url
        self.queue = DispatchQueue(label: queueLabel)
        ensureParentDirectoryExists()
        load()
    }

    // MARK: - Public API

    /// Check if a source is in this store
    public func contains(_ source: MediaSource) -> Bool {
        queue.sync {
            identifiers.contains(identifier(for: source))
        }
    }

    /// Add a source to the store
    public func add(_ source: MediaSource) {
        queue.sync {
            identifiers.insert(identifier(for: source))
            save()
        }
    }

    /// Remove a source from the store
    public func remove(_ source: MediaSource) {
        queue.sync {
            identifiers.remove(identifier(for: source))
            save()
        }
    }

    /// Toggle a source's presence in the store, returns new state (true = now in store)
    @discardableResult
    public func toggle(_ source: MediaSource) -> Bool {
        queue.sync {
            let id = identifier(for: source)
            if identifiers.contains(id) {
                identifiers.remove(id)
                save()
                return false
            } else {
                identifiers.insert(id)
                save()
                return true
            }
        }
    }

    /// Number of items in the store
    public var count: Int {
        queue.sync { identifiers.count }
    }

    /// Get all identifiers (for batch processing)
    public var allIdentifiers: [String] {
        queue.sync { Array(identifiers) }
    }

    /// Clear all items from the store
    public func clearAll() {
        queue.sync {
            identifiers.removeAll()
            save()
        }
    }

    // MARK: - Internal

    /// Extract a stable identifier from the source for persistence
    func identifier(for source: MediaSource) -> String {
        switch source {
        case .url(let url):
            return "file:" + url.standardizedFileURL.path
        case .external(let id):
            return "external:" + id
        }
    }

    private func load() {
        guard let data = try? Data(contentsOf: storeURL) else { return }
        if let list = try? JSONDecoder().decode([String].self, from: data) {
            identifiers = Set(list)
        }
    }

    private func save() {
        let list = Array(identifiers)
        if let data = try? JSONEncoder().encode(list) {
            try? data.write(to: storeURL)
        }
    }

    private func ensureParentDirectoryExists() {
        let dir = storeURL.deletingLastPathComponent()
        let fm = FileManager.default
        if !fm.fileExists(atPath: dir.path) {
            try? fm.createDirectory(at: dir, withIntermediateDirectories: true, attributes: nil)
        }
    }
}

// MARK: - Specialized Stores

/// Persistent exclusion list for source media.
/// Sources in this store are filtered out of the media library.
public final class ExclusionStore: PersistentIdentifierStore {
    public init(url: URL) {
        super.init(url: url, queueLabel: "ExclusionStore.queue")
    }

    /// Check if a source is excluded (convenience alias)
    public func isExcluded(_ source: MediaSource) -> Bool {
        contains(source)
    }
}

/// Persistent queue of sources marked for deletion.
/// The actual deletion is deferred - this just tracks the list.
public final class DeleteStore: PersistentIdentifierStore {
    public init(url: URL) {
        super.init(url: url, queueLabel: "DeleteStore.queue")
    }

    /// Check if a source is queued for deletion (convenience alias)
    public func isQueued(_ source: MediaSource) -> Bool {
        contains(source)
    }

    /// Get all queued identifiers (convenience alias for processing)
    public var allQueued: [String] {
        allIdentifiers
    }
}

