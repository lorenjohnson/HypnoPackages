//
//  EffectsSession.swift
//  Hypnograph
//
//  Single source of truth for effect chains in a given context.
//  Each mode (montage, sequence, live) has its own session instance.
//

import Foundation
import CryptoKit

/// Manages a set of effect chains with load/save and live update support.
/// Each session is backed by a JSON file and provides edit APIs with debounced persistence.
@MainActor
public final class EffectsSession: ObservableObject {

    // MARK: - Published State

    /// The effect chains in this session (single source of truth)
    @Published public private(set) var chains: [EffectChain] = [] {
        didSet {
            // Keep thread-safe copy in sync
            _chainsLock.lock()
            _chainsCopy = chains
            _chainsLock.unlock()
        }
    }

    // MARK: - Thread-Safe Access

    /// Lock for thread-safe access to chains from non-main-actor contexts
    private nonisolated(unsafe) let _chainsLock = NSLock()

    /// Thread-safe copy of chains - nonisolated(unsafe) because we protect with lock
    private nonisolated(unsafe) var _chainsCopy: [EffectChain] = []

    /// Thread-safe snapshot of chains for use from non-main-actor contexts
    /// This is a copy, so modifications won't affect the session
    public nonisolated var chainsSnapshot: [EffectChain] {
        _chainsLock.lock()
        defer { _chainsLock.unlock() }
        return _chainsCopy
    }

    /// Whether there are unsaved changes
    @Published public private(set) var isDirty: Bool = false
    
    // MARK: - Callbacks
    
    /// Fired when a chain is updated (for live preview push)
    /// Parameters: (chainIndex, updatedChain)
    public var onChainUpdated: ((Int, EffectChain) -> Void)?
    
    /// Fired when the session is reloaded from disk
    public var onSessionReloaded: (() -> Void)?

    // MARK: - Private State
    
    private let fileURL: URL
    private var savedConfigHash: String?
    private var saveTimer: Timer?
    private let saveDebounceInterval: TimeInterval = 0.3
    private var pendingInstantiations: Set<Int> = []
    
    // MARK: - Init
    
    /// Create a session backed by a specific file URL
    public init(fileURL: URL) {
        self.fileURL = fileURL
        loadFromDisk()
    }
    
    /// Create a session with a filename in the standard effects directory
    public convenience init(filename: String) {
        let directory = HypnoCoreConfig.shared.effectLibrariesDirectory
        let url = directory.appendingPathComponent(filename)
        self.init(fileURL: url)
    }
    
    // MARK: - Load/Save
    
    /// Load chains from disk (replaces current state)
    public func loadFromDisk() {
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            // No file yet - start with bundled defaults
            chains = EffectsSession.loadBundledDefaults()
            updateSavedHash()
            return
        }

        do {
            let data = try Data(contentsOf: fileURL)
            let config = try JSONDecoder().decode(EffectLibraryConfig.self, from: data)
            chains = config.effects
            updateSavedHash()
            print("✅ EffectsSession: Loaded \(chains.count) chains from \(fileURL.lastPathComponent)")
        } catch {
            print("⚠️ EffectsSession: Failed to load from \(fileURL.lastPathComponent): \(error)")
            chains = EffectsSession.loadBundledDefaults()
            updateSavedHash()
        }

        onSessionReloaded?()
    }

    /// Replace all chains with new ones (used when loading an effects library from file or hypnogram snapshot)
    public func replaceChains(_ newChains: [EffectChain]) {
        chains = newChains
        markDirty()
        scheduleSave()
        onSessionReloaded?()
    }

    /// Save current chains to disk
    public func saveToDisk() {
        let config = EffectLibraryConfig(version: 1, effects: chains)
        
        DispatchQueue.global(qos: .utility).async { [weak self, fileURL] in
            do {
                let encoder = JSONEncoder()
                encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
                let data = try encoder.encode(config)
                try data.write(to: fileURL, options: .atomic)
                print("✅ EffectsSession: Saved to \(fileURL.lastPathComponent)")
                
                DispatchQueue.main.async {
                    self?.updateSavedHash()
                }
            } catch {
                print("⚠️ EffectsSession: Failed to save: \(error)")
            }
        }
    }
    
    /// Save to a specific URL (for export)
    public func save(to url: URL) {
        let config = EffectLibraryConfig(version: 1, effects: chains)
        
        DispatchQueue.global(qos: .utility).async {
            do {
                let encoder = JSONEncoder()
                encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
                let data = try encoder.encode(config)
                try data.write(to: url, options: .atomic)
                print("✅ EffectsSession: Exported to \(url.lastPathComponent)")
            } catch {
                print("⚠️ EffectsSession: Failed to export: \(error)")
            }
        }
    }
    
    // MARK: - Dirty Tracking
    
    private func updateSavedHash() {
        savedConfigHash = computeHash()
        isDirty = false
    }
    
    private func markDirty() {
        let currentHash = computeHash()
        isDirty = currentHash != savedConfigHash
    }
    
    private func computeHash() -> String {
        let config = EffectLibraryConfig(version: 1, effects: chains)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(config) else { return "" }
        let digest = SHA256.hash(data: data)
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    // MARK: - Edit APIs

    /// Update a parameter value in a chain's effect
    public func updateParameter(chainIndex: Int, effectIndex: Int?, key: String, value: AnyCodableValue) {
        guard chainIndex >= 0 && chainIndex < chains.count else { return }

        var chain = chains[chainIndex]

        if let effectIdx = effectIndex {
            // Update an effect definition's parameter
            guard effectIdx >= 0 && effectIdx < chain.effects.count else { return }
            var params = chain.effects[effectIdx].params ?? [:]
            params[key] = value
            chain.effects[effectIdx].params = params
        } else {
            // Update the chain's own parameter
            var params = chain.params ?? [:]
            params[key] = value
            chain.params = params
        }

        chains[chainIndex] = chain
        markDirty()
        scheduleInstantiationAndSave(chainIndex: chainIndex)
    }

    /// Add an effect to a chain
    public func addEffectToChain(chainIndex: Int, effectType: String) {
        guard chainIndex >= 0 && chainIndex < chains.count else { return }

        var chain = chains[chainIndex]
        let defaultParams = EffectRegistry.defaults(for: effectType)
        let newEffect = EffectDefinition(type: effectType, params: defaultParams)
        chain.effects.append(newEffect)

        chains[chainIndex] = chain
        markDirty()
        scheduleInstantiationAndSave(chainIndex: chainIndex)
    }

    /// Remove an effect from a chain
    public func removeEffectFromChain(chainIndex: Int, effectIndex: Int) {
        guard chainIndex >= 0 && chainIndex < chains.count else { return }

        var chain = chains[chainIndex]
        guard effectIndex >= 0 && effectIndex < chain.effects.count else { return }

        chain.effects.remove(at: effectIndex)
        chains[chainIndex] = chain
        markDirty()
        scheduleInstantiationAndSave(chainIndex: chainIndex)
    }

    /// Reorder effects within a chain
    public func reorderEffectsInChain(chainIndex: Int, fromIndex: Int, toIndex: Int) {
        guard chainIndex >= 0 && chainIndex < chains.count else { return }

        var chain = chains[chainIndex]
        guard fromIndex >= 0 && fromIndex < chain.effects.count else { return }
        guard toIndex >= 0 && toIndex < chain.effects.count else { return }

        let effect = chain.effects.remove(at: fromIndex)
        chain.effects.insert(effect, at: toIndex)

        chains[chainIndex] = chain
        markDirty()
        scheduleInstantiationAndSave(chainIndex: chainIndex)
    }

    /// Toggle effect enabled state
    public func setEffectEnabled(chainIndex: Int, effectIndex: Int, enabled: Bool) {
        updateParameter(chainIndex: chainIndex, effectIndex: effectIndex, key: "_enabled", value: .bool(enabled))
    }

    /// Reset an effect's parameters to defaults
    public func resetEffectToDefaults(chainIndex: Int, effectIndex: Int) {
        guard chainIndex >= 0 && chainIndex < chains.count else { return }

        var chain = chains[chainIndex]
        guard effectIndex >= 0 && effectIndex < chain.effects.count else { return }

        let effectDef = chain.effects[effectIndex]
        var defaults = EffectRegistry.defaults(for: effectDef.type)

        // Preserve _enabled state
        if let wasEnabled = effectDef.params?["_enabled"] {
            defaults["_enabled"] = wasEnabled
        }

        chain.effects[effectIndex].params = defaults
        chains[chainIndex] = chain
        markDirty()
        scheduleInstantiationAndSave(chainIndex: chainIndex)
    }

    /// Update the name of a chain
    public func updateChainName(chainIndex: Int, name: String) {
        guard chainIndex >= 0 && chainIndex < chains.count else { return }

        var chain = chains[chainIndex]
        chain.name = name
        chains[chainIndex] = chain
        markDirty()
        scheduleInstantiationAndSave(chainIndex: chainIndex)
    }

    /// Create a new chain with BasicEffect as default
    @discardableResult
    public func createNewChain() -> Int {
        // Generate unique name
        let baseName = "Effect"
        let existingNames = Set(chains.compactMap { $0.name })
        var uniqueName = baseName
        var counter = 1
        while existingNames.contains(uniqueName) {
            counter += 1
            uniqueName = "\(baseName) \(counter)"
        }

        // Create chain with BasicEffect
        let basicDefaults = EffectRegistry.defaults(for: "BasicEffect")
        let basicEffect = EffectDefinition(type: "BasicEffect", params: basicDefaults)
        let newChain = EffectChain(name: uniqueName, effects: [basicEffect])

        chains.append(newChain)
        markDirty()
        scheduleSave()

        return chains.count - 1
    }

    /// Delete a chain at the given index
    public func deleteChain(at index: Int) {
        guard index >= 0 && index < chains.count else { return }
        chains.remove(at: index)
        markDirty()
        scheduleSave()
    }

    /// Get chain by name
    public func chain(named name: String) -> EffectChain? {
        chains.first { $0.name == name }
    }

    // MARK: - Debounced Save

    private func scheduleInstantiationAndSave(chainIndex: Int) {
        pendingInstantiations.insert(chainIndex)
        saveTimer?.invalidate()

        saveTimer = Timer.scheduledTimer(withTimeInterval: saveDebounceInterval, repeats: false) { [weak self] _ in
            Task { @MainActor in
                self?.performPendingInstantiations()
                self?.saveToDisk()
            }
        }
    }

    private func scheduleSave() {
        saveTimer?.invalidate()

        saveTimer = Timer.scheduledTimer(withTimeInterval: saveDebounceInterval, repeats: false) { [weak self] _ in
            Task { @MainActor in
                self?.saveToDisk()
            }
        }
    }

    private func performPendingInstantiations() {
        for chainIndex in pendingInstantiations {
            guard chainIndex >= 0 && chainIndex < chains.count else { continue }
            let chain = chains[chainIndex]
            onChainUpdated?(chainIndex, chain)
        }
        pendingInstantiations.removeAll()
    }

    // MARK: - Import/Merge

    /// Merge chains from another source (e.g., a loaded recipe)
    /// Overwrites existing chains with the same name
    public func merge(chains newChains: [EffectChain]) {
        var merged = chains

        for newChain in newChains {
            if let existingIndex = merged.firstIndex(where: { $0.name == newChain.name }) {
                merged[existingIndex] = newChain
            } else {
                merged.append(newChain)
            }
        }

        chains = merged
        markDirty()
        scheduleSave()
        onSessionReloaded?()
    }

    // MARK: - Public Save API

    /// Whether there are unsaved changes
    public var hasUnsavedChanges: Bool {
        isDirty
    }

    /// Save immediately (for manual save operations)
    public func save() {
        saveToDisk()
    }

    // MARK: - Bundled Defaults

    /// URL to bundled default effects JSON file
    private nonisolated static var bundledDefaultsURL: URL? {
        HypnoEffectsBundle.bundle.url(forResource: "effects-default", withExtension: "json")
    }

    /// Load default effect chains from bundled JSON, with minimal hardcoded fallback
    /// Nonisolated since it only does synchronous file I/O
    public nonisolated static func loadBundledDefaults() -> [EffectChain] {
        guard let url = bundledDefaultsURL else {
            print("⚠️ EffectsSession: Bundled effects-default.json not found, using minimal fallback")
            return minimalFallbackDefaults
        }

        do {
            let data = try Data(contentsOf: url)
            let config = try JSONDecoder().decode(EffectLibraryConfig.self, from: data)
            print("✅ EffectsSession: Loaded \(config.effects.count) default chains from bundle")
            return config.effects
        } catch {
            print("⚠️ EffectsSession: Failed to decode bundled defaults: \(error)")
            return minimalFallbackDefaults
        }
    }

    /// Minimal fallback if bundled JSON is missing or corrupt
    private nonisolated static let minimalFallbackDefaults: [EffectChain] = [
        EffectChain(name: "Basic", effects: [
            EffectDefinition(type: "BasicEffect", params: nil)
        ])
    ]
}
