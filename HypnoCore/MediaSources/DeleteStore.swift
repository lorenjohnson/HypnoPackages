//
//  DeleteStore.swift
//  Hypnograph
//
//  Persistent queue of sources marked for deletion.
//  Similar to ExclusionStore but for files the user wants to actually remove.
//

import Foundation

/// Persistent queue of sources the user has marked for deletion.
/// The actual deletion is deferred - this just tracks the list.
public final class DeleteStore {
    private var queuedIdentifiers: Set<String> = []
    private let queue = DispatchQueue(label: "DeleteStore.queue")
    private let storeURL: URL

    public init(url: URL) {
        self.storeURL = url
        ensureParentDirectoryExists()
        load()
    }

    /// Check if a source is queued for deletion
    public func isQueued(_ source: MediaFile.Source) -> Bool {
        queue.sync {
            queuedIdentifiers.contains(identifier(for: source))
        }
    }

    /// Add a source to the delete queue
    public func add(_ source: MediaFile.Source) {
        queue.sync {
            queuedIdentifiers.insert(identifier(for: source))
            save()
        }
    }

    /// Remove a source from the delete queue (if user changes their mind)
    public func remove(_ source: MediaFile.Source) {
        queue.sync {
            queuedIdentifiers.remove(identifier(for: source))
            save()
        }
    }

    /// Get all queued identifiers (for processing)
    public var allQueued: [String] {
        queue.sync {
            Array(queuedIdentifiers)
        }
    }

    /// Clear the entire queue
    public func clearAll() {
        queue.sync {
            queuedIdentifiers.removeAll()
            save()
        }
    }

    /// Number of items in queue
    public var count: Int {
        queue.sync { queuedIdentifiers.count }
    }

    // MARK: - Private

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
        guard let data = try? Data(contentsOf: storeURL) else { return }
        if let list = try? JSONDecoder().decode([String].self, from: data) {
            queuedIdentifiers = Set(list)
        }
    }

    private func save() {
        let list = Array(queuedIdentifiers)
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
