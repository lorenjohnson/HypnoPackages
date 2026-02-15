//
//  EffectsSession.swift
//  HypnoCore
//
//  Single source of truth for effect chains in a given context.
//  Each playback context (preview, live, export) typically owns its own session instance.
//  Built on PersistentStore for automatic persistence.
//

import Foundation
import Combine

/// Manages a set of effect chains with load/save and live update support.
/// Each session is backed by a JSON file and provides edit APIs with debounced persistence.
@MainActor
public final class EffectsSession: PersistentStore<EffectLibraryConfig> {

    // MARK: - Convenience Accessors

    /// The effect chains in this session
    public var chains: [EffectChain] {
        get { value.effectChains }
    }

    /// Publisher for chains (maps from $value for reactive UI binding)
    public var chainsPublisher: some Publisher<[EffectChain], Never> {
        $value.map { $0.effectChains }
    }

    /// Thread-safe snapshot of chains for non-main-actor contexts
    public nonisolated var chainsSnapshot: [EffectChain] {
        snapshot.effectChains
    }

    // MARK: - Callbacks

    /// Fired when a chain is updated (for live preview push)
    /// Parameters: (chainIndex, updatedChain)
    public var onChainUpdated: ((Int, EffectChain) -> Void)?

    // MARK: - Private State

    private var pendingInstantiations: Set<Int> = []
    private var instantiationTimer: Timer?
    private let instantiationDebounceInterval: TimeInterval = 0.3

    // MARK: - Init

    /// Create a session backed by a specific file URL
    public init(fileURL: URL) {
        let defaultConfig = EffectLibraryConfig(
            version: 1,
            effectChains: EffectsSession.loadBundledDefaults()
        )
        super.init(fileURL: fileURL, default: defaultConfig)
    }

    /// Create a session with a filename in the standard effects directory
    public convenience init(filename: String) {
        let directory = HypnoCoreConfig.shared.effectLibrariesDirectory
        let url = directory.appendingPathComponent(filename)
        self.init(fileURL: url)
    }

    // MARK: - Chain Mutation Helpers

    /// Update chains and trigger instantiation callback
    private func updateChains(_ transform: (inout [EffectChain]) -> Void, notifyIndex: Int? = nil) {
        update { config in
            var chains = config.effectChains
            transform(&chains)
            config = EffectLibraryConfig(version: config.version, effectChains: chains)
        }
        if let index = notifyIndex {
            scheduleInstantiation(chainIndex: index)
        }
    }

    // MARK: - Edit APIs

    /// Update a parameter value in a chain's effect
    public func updateParameter(chainIndex: Int, effectIndex: Int?, key: String, value: AnyCodableValue) {
        guard chainIndex >= 0 && chainIndex < chains.count else { return }

        updateChains({ effects in
            let chain = effects[chainIndex]

            if let effectIdx = effectIndex {
                guard effectIdx >= 0 && effectIdx < chain.effects.count else { return }
                var params = chain.effects[effectIdx].params ?? [:]
                params[key] = value
                chain.effects[effectIdx].params = params
            } else {
                var params = chain.params ?? [:]
                params[key] = value
                chain.params = params
            }

            effects[chainIndex] = chain
        }, notifyIndex: chainIndex)
    }

    /// Add an effect to a chain
    public func addEffectToChain(chainIndex: Int, effectType: String) {
        guard chainIndex >= 0 && chainIndex < chains.count else { return }

        updateChains({ effects in
            let chain = effects[chainIndex]
            let defaultParams = EffectRegistry.defaults(for: effectType)
            let newEffect = EffectDefinition(type: effectType, params: defaultParams)
            chain.effects.append(newEffect)
            effects[chainIndex] = chain
        }, notifyIndex: chainIndex)
    }

    /// Remove an effect from a chain
    public func removeEffectFromChain(chainIndex: Int, effectIndex: Int) {
        guard chainIndex >= 0 && chainIndex < chains.count else { return }

        updateChains({ effects in
            let chain = effects[chainIndex]
            guard effectIndex >= 0 && effectIndex < chain.effects.count else { return }
            chain.effects.remove(at: effectIndex)
            effects[chainIndex] = chain
        }, notifyIndex: chainIndex)
    }

    /// Reorder effects within a chain
    public func reorderEffectsInChain(chainIndex: Int, fromIndex: Int, toIndex: Int) {
        guard chainIndex >= 0 && chainIndex < chains.count else { return }

        updateChains({ effects in
            let chain = effects[chainIndex]
            guard fromIndex >= 0 && fromIndex < chain.effects.count else { return }
            guard toIndex >= 0 && toIndex < chain.effects.count else { return }

            let effect = chain.effects.remove(at: fromIndex)
            chain.effects.insert(effect, at: toIndex)
            effects[chainIndex] = chain
        }, notifyIndex: chainIndex)
    }

    /// Toggle effect enabled state
    public func setEffectEnabled(chainIndex: Int, effectIndex: Int, enabled: Bool) {
        updateParameter(chainIndex: chainIndex, effectIndex: effectIndex, key: "_enabled", value: .bool(enabled))
    }

    /// Reset an effect's parameters to defaults
    public func resetEffectToDefaults(chainIndex: Int, effectIndex: Int) {
        guard chainIndex >= 0 && chainIndex < chains.count else { return }

        updateChains({ effects in
            let chain = effects[chainIndex]
            guard effectIndex >= 0 && effectIndex < chain.effects.count else { return }

            let effectDef = chain.effects[effectIndex]
            var defaults = EffectRegistry.defaults(for: effectDef.type)

            // Preserve _enabled state
            if let wasEnabled = effectDef.params?["_enabled"] {
                defaults["_enabled"] = wasEnabled
            }

            chain.effects[effectIndex].params = defaults
            effects[chainIndex] = chain
        }, notifyIndex: chainIndex)
    }

    /// Randomize all parameters for an effect in a chain
    public func randomizeEffect(chainIndex: Int, effectIndex: Int) {
        guard chainIndex >= 0 && chainIndex < chains.count else { return }

        updateChains({ effects in
            let chain = effects[chainIndex]
            guard effectIndex >= 0 && effectIndex < chain.effects.count else { return }

            let effectDef = chain.effects[effectIndex]
            let specs = EffectRegistry.parameterSpecs(for: effectDef.type)
            var randomParams: [String: AnyCodableValue] = [:]

            for (key, spec) in specs {
                randomParams[key] = spec.randomValue()
            }

            // Preserve _enabled state
            if let wasEnabled = effectDef.params?["_enabled"] {
                randomParams["_enabled"] = wasEnabled
            }

            chain.effects[effectIndex].params = randomParams
            effects[chainIndex] = chain
        }, notifyIndex: chainIndex)
    }

    /// Update the name of a chain
    public func updateChainName(chainIndex: Int, name: String) {
        guard chainIndex >= 0 && chainIndex < chains.count else { return }

        updateChains({ effects in
            let chain = effects[chainIndex]
            chain.name = name
            effects[chainIndex] = chain
        }, notifyIndex: chainIndex)
    }

    /// Create a new chain with BasicEffect as default
    @discardableResult
    public func createNewChain() -> Int {
        let baseName = "Effect"
        let existingNames = Set(chains.compactMap { $0.name })
        var uniqueName = baseName
        var counter = 1
        while existingNames.contains(uniqueName) {
            counter += 1
            uniqueName = "\(baseName) \(counter)"
        }

        let basicDefaults = EffectRegistry.defaults(for: "BasicEffect")
        let basicEffect = EffectDefinition(type: "BasicEffect", params: basicDefaults)
        let newChain = EffectChain(name: uniqueName, effects: [basicEffect])

        updateChains { effects in
            effects.append(newChain)
        }

        return chains.count - 1
    }

    /// Delete a chain at the given index
    public func deleteChain(at index: Int) {
        guard index >= 0 && index < chains.count else { return }
        updateChains { effects in
            effects.remove(at: index)
        }
    }

    /// Reorder chains by identity. Used by drag/drop in library UIs.
    public func moveChain(fromID: UUID, toID: UUID) {
        guard let fromIndex = chainIndex(id: fromID), let toIndex = chainIndex(id: toID) else { return }
        guard fromIndex != toIndex else { return }

        updateChains { effects in
            guard fromIndex >= 0, fromIndex < effects.count, toIndex >= 0, toIndex < effects.count else { return }
            let moved = effects.remove(at: fromIndex)
            var destination = toIndex
            if fromIndex < toIndex {
                destination -= 1
            }
            effects.insert(moved, at: max(0, min(destination, effects.count)))
        }
    }

    public func chainIndex(id: UUID) -> Int? {
        chains.firstIndex { $0.id == id }
    }

    public func chain(id: UUID) -> EffectChain? {
        guard let idx = chainIndex(id: id) else { return nil }
        return chains[idx]
    }

    /// Create a new template entry from a chain, ensuring template semantics (no sourceTemplateId).
    /// Returns the new template's id.
    @discardableResult
    public func addTemplate(from chain: EffectChain, name: String? = nil) -> UUID {
        let template = EffectChain(duplicating: chain, sourceTemplateId: nil)
        if let name, !name.isEmpty {
            template.name = name
        }
        // Templates should not themselves be linked to other templates.
        template.sourceTemplateId = nil

        updateChains { effects in
            effects.append(template)
        }
        return template.id
    }

    /// Replace an existing template in-place by id, preserving identity and name by default.
    public func updateTemplate(id: UUID, from chain: EffectChain, preserveName: Bool = true) {
        guard let idx = chainIndex(id: id) else { return }

        updateChains({ effects in
            let existingName = effects[idx].name
            let newTemplate = EffectChain(duplicating: chain, sourceTemplateId: nil)
            newTemplate.id = id
            newTemplate.sourceTemplateId = nil
            if preserveName {
                newTemplate.name = existingName
            }
            effects[idx] = newTemplate
        }, notifyIndex: idx)
    }

    /// Duplicate a template by id (or any chain), returning the new template id.
    @discardableResult
    public func duplicateTemplate(id: UUID, name: String? = nil) -> UUID? {
        guard let template = chain(id: id) else { return nil }
        let baseName = template.name ?? "Effect"
        let newName = name ?? "\(baseName) Copy"
        return addTemplate(from: template, name: newName)
    }

    public func deleteChain(id: UUID) {
        guard let idx = chainIndex(id: id) else { return }
        deleteChain(at: idx)
    }

    /// Get chain by name
    public func chain(named name: String) -> EffectChain? {
        chains.first { $0.name == name }
    }

    /// Replace all chains (used when loading from external source)
    public func replaceChains(_ newChains: [EffectChain]) {
        replace(EffectLibraryConfig(version: 1, effectChains: newChains))
    }

    /// Merge chains from another source (e.g., a loaded recipe)
    /// Overwrites existing chains with the same name
    public func merge(chains newChains: [EffectChain]) {
        updateChains { effects in
            for newChain in newChains {
                if let existingIndex = effects.firstIndex(where: { $0.name == newChain.name }) {
                    effects[existingIndex] = newChain
                } else {
                    effects.append(newChain)
                }
            }
        }
    }

    // MARK: - Instantiation Callbacks

    private func scheduleInstantiation(chainIndex: Int) {
        pendingInstantiations.insert(chainIndex)
        instantiationTimer?.invalidate()

        instantiationTimer = Timer.scheduledTimer(withTimeInterval: instantiationDebounceInterval, repeats: false) { [weak self] _ in
            Task { @MainActor in
                self?.performPendingInstantiations()
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

    // MARK: - Bundled Defaults

    /// URL to bundled default effects JSON file
    private nonisolated static var bundledDefaultsURL: URL? {
        HypnoEffectsBundle.bundle.url(forResource: "effects-default", withExtension: "json")
    }

    /// Load default effect chains from bundled JSON, with minimal hardcoded fallback
    public nonisolated static func loadBundledDefaults() -> [EffectChain] {
        guard let url = bundledDefaultsURL else {
            print("⚠️ EffectsSession: Bundled effects-default.json not found, using minimal fallback")
            return minimalFallbackDefaults
        }

        do {
            let data = try Data(contentsOf: url)
            let config = try JSONDecoder().decode(EffectLibraryConfig.self, from: data)
            print("✅ EffectsSession: Loaded \(config.effectChains.count) default chains from bundle")
            return config.effectChains
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
