//
//  PersistentStore.swift
//  HypnoCore
//
//  Generic reactive persistent store for any Codable type.
//  Provides automatic debounced saving, dirty tracking, and SwiftUI-compatible observation.
//
//  Usage:
//    let store = PersistentStore(fileURL: url, default: MySettings.default)
//    store.update { $0.someSetting = newValue }  // Auto-saves after debounce
//

import Foundation
import Combine
import CryptoKit

/// Generic reactive persistent store for any Codable type.
/// Provides @Published value, debounced auto-save, and dirty tracking.
@MainActor
open class PersistentStore<T: Codable>: ObservableObject {

    // MARK: - Published State

    /// The current value (single source of truth)
    @Published public private(set) var value: T {
        didSet {
            // Keep thread-safe copy in sync
            _valueLock.lock()
            _valueCopy = value
            _valueLock.unlock()
        }
    }

    /// Whether there are unsaved changes
    @Published public private(set) var isDirty: Bool = false

    // MARK: - Thread-Safe Access

    /// Lock for thread-safe access from non-main-actor contexts
    private nonisolated(unsafe) let _valueLock = NSLock()

    /// Thread-safe copy of value
    private nonisolated(unsafe) var _valueCopy: T

    /// Thread-safe snapshot for use from non-main-actor contexts
    /// This is a copy, so modifications won't affect the store
    public nonisolated var snapshot: T {
        _valueLock.lock()
        defer { _valueLock.unlock() }
        return _valueCopy
    }

    // MARK: - Configuration

    /// The file URL for persistence
    public let fileURL: URL

    /// Debounce interval for saves (default 0.3s)
    public var saveDebounceInterval: TimeInterval = 0.3

    /// Called after the store is reloaded from disk
    public var onReloaded: (() -> Void)?

    // MARK: - Private State

    private let defaultValue: T
    private var savedHash: String?
    private var saveTimer: Timer?

    // MARK: - Init

    /// Create a store backed by a file URL with a default value
    /// - Parameters:
    ///   - fileURL: The file to persist to
    ///   - default: Default value if file doesn't exist or can't be decoded
    public init(fileURL: URL, default defaultValue: T) {
        self.fileURL = fileURL
        self.defaultValue = defaultValue
        self._valueCopy = defaultValue
        self.value = defaultValue

        ensureParentDirectoryExists()
        loadFromDisk()
    }

    // MARK: - Public API

    /// Update the value and schedule a debounced save.
    /// This is the primary way to modify the store.
    public func update(_ transform: (inout T) -> Void) {
        transform(&value)
        markDirty()
        scheduleSave()
    }

    /// Replace the entire value (used when loading from external source)
    public func replace(_ newValue: T) {
        value = newValue
        markDirty()
        scheduleSave()
        onReloaded?()
    }

    /// Reload from disk, discarding any unsaved changes
    public func reload() {
        loadFromDisk()
        onReloaded?()
    }

    /// Save immediately (bypasses debounce)
    /// If `to` is provided, exports to that URL without affecting store state
    public func save(to url: URL? = nil) {
        saveTimer?.invalidate()
        saveTimer = nil
        saveToDisk(to: url)
    }

    /// Whether there are unsaved changes
    public var hasUnsavedChanges: Bool { isDirty }

    // MARK: - Load/Save

    private func loadFromDisk() {
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            value = defaultValue
            updateSavedHash()
            return
        }

        do {
            let data = try Data(contentsOf: fileURL)
            let decoded = try JSONDecoder().decode(T.self, from: data)
            value = decoded
            updateSavedHash()
            print("✅ PersistentStore: Loaded from \(fileURL.lastPathComponent)")
        } catch {
            print("⚠️ PersistentStore: Failed to load from \(fileURL.lastPathComponent): \(error)")
            value = defaultValue
            updateSavedHash()
        }
    }

    private func saveToDisk(to exportURL: URL? = nil) {
        let valueToSave = value
        let targetURL = exportURL ?? fileURL
        let isExport = exportURL != nil

        DispatchQueue.global(qos: .utility).async { [weak self] in
            do {
                let encoder = JSONEncoder()
                encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
                let data = try encoder.encode(valueToSave)
                try data.write(to: targetURL, options: .atomic)
                print("✅ PersistentStore: \(isExport ? "Exported" : "Saved") to \(targetURL.lastPathComponent)")

                // Only update hash for saves to the store's own file
                if !isExport {
                    Task { @MainActor in
                        self?.updateSavedHash()
                    }
                }
            } catch {
                print("⚠️ PersistentStore: Failed to \(isExport ? "export" : "save") to \(targetURL.lastPathComponent): \(error)")
            }
        }
    }

    // MARK: - Dirty Tracking

    private func updateSavedHash() {
        savedHash = computeHash()
        isDirty = false
    }

    private func markDirty() {
        let currentHash = computeHash()
        isDirty = currentHash != savedHash
    }

    private func computeHash() -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(value) else { return "" }
        let digest = SHA256.hash(data: data)
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    // MARK: - Debounced Save

    private func scheduleSave() {
        saveTimer?.invalidate()

        saveTimer = Timer.scheduledTimer(withTimeInterval: saveDebounceInterval, repeats: false) { [weak self] _ in
            Task { @MainActor in
                self?.saveToDisk()
            }
        }
    }

    // MARK: - Filesystem

    private func ensureParentDirectoryExists() {
        let dir = fileURL.deletingLastPathComponent()
        let fm = FileManager.default
        if !fm.fileExists(atPath: dir.path) {
            try? fm.createDirectory(at: dir, withIntermediateDirectories: true, attributes: nil)
        }
    }
}
