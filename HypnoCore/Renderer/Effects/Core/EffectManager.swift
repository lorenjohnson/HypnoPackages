//
//  EffectManager.swift
//  Hypnograph
//
//  Manages effect state, frame buffer, and effect application.
//  Coordinates between the recipe (source of truth) and the rendering pipeline.
//

import AVFoundation
import CoreGraphics
import CoreMedia
import CoreImage
import Foundation

/// Manages effect state, frame buffer, and effect application.
/// Coordinates between the recipe (source of truth) and the rendering pipeline.
public final class EffectManager {

    // MARK: - Frame Buffer

    /// Shared frame buffer that persists across frames
    /// 120 frames at 30fps = 4 seconds of history for advanced datamosh/AI effects
    let frameBuffer: FrameBuffer

    /// Global frame counter - increments each frame, persists across video loops
    /// Used by temporal effects that need consistent timing
    public private(set) var globalFrameIndex: Int = 0

    /// Increment frame counter and return current value
    public func nextFrameIndex() -> Int {
        let current = globalFrameIndex
        globalFrameIndex += 1
        return current
    }

    /// Reset frame counter (call when switching montages or effects)
    public func resetFrameIndex() {
        globalFrameIndex = 0
    }

    /// Create a manager for export with a frozen composition snapshot.
    /// Uses same code paths as preview but with isolated state
    public static func forExport(composition: Composition) -> EffectManager {
        let manager = EffectManager()
        manager.compositionProvider = { composition }
        // No setters needed - export is read-only
        // flashSoloIndex stays nil - export renders all layers
        return manager
    }

    @available(*, deprecated, renamed: "forExport(composition:)")
    public static func forExport(clip: Composition) -> EffectManager {
        forExport(composition: clip)
    }

    /// Create an isolated manager for transition playback with a frozen composition snapshot.
    /// Optionally preserves temporal render state from this manager so the outgoing composition
    /// continues smoothly during overlap.
    public func makeTransitionSnapshotManager(
        frozenComposition: Composition,
        preserveTemporalState: Bool = true
    ) -> EffectManager {
        let clonedBuffer: FrameBuffer
        if preserveTemporalState {
            clonedBuffer = frameBuffer.cloneState()
        } else {
            clonedBuffer = FrameBuffer(maxFrames: frameBuffer.maxFrames)
        }

        let manager = EffectManager(frameBuffer: clonedBuffer)
        manager.globalFrameIndex = globalFrameIndex
        manager.session = session
        manager.recentStore = recentStore
        manager.flashSoloIndex = flashSoloIndex
        manager.isCompositionEffectSuspended = isCompositionEffectSuspended
        manager.isNormalizationEnabled = isNormalizationEnabled
        manager._normalizationStrategy = _normalizationStrategy
        manager.compositionProvider = { frozenComposition }
        return manager
    }

    @available(*, deprecated, renamed: "makeTransitionSnapshotManager(frozenComposition:preserveTemporalState:)")
    public func makeTransitionSnapshotManager(
        frozenClip: Composition,
        preserveTemporalState: Bool = true
    ) -> EffectManager {
        makeTransitionSnapshotManager(
            frozenComposition: frozenClip,
            preserveTemporalState: preserveTemporalState
        )
    }

    /// Get the maximum lookback required by any effect (composition or per-layer).
    public var maxRequiredLookback: Int {
        guard let composition = compositionProvider?() else { return 0 }

        // Check composition effect chain
        let globalMax = composition.effectChain.maxRequiredLookback

        // Check per-layer effect chains
        let layerMax = composition.layers.map { $0.effectChain.maxRequiredLookback }.max() ?? 0

        return max(globalMax, layerMax)
    }

    /// Whether any effect in the recipe uses the frame buffer (has temporal dependencies)
    public var usesFrameBuffer: Bool {
        maxRequiredLookback > 0
    }

    // Compatibility alias for frameIndex
    public var frameIndex: Int { globalFrameIndex }

    /// Most recently rendered frame (useful for snapshots)
    public var currentFrame: CIImage? { frameBuffer.currentFrame }

    // MARK: - Recipe Integration

    /// Closure to get the current composition (injected by the owning feature).
    public var compositionProvider: (() -> Composition?)?

    @available(*, deprecated, renamed: "compositionProvider")
    public var clipProvider: (() -> Composition?)? {
        get { compositionProvider }
        set { compositionProvider = newValue }
    }

    /// Closure to set composition effect chain
    public var compositionEffectChainSetter: ((EffectChain) -> Void)?

    /// Closure to set per-source effect chain
    public var sourceEffectChainSetter: ((Int, EffectChain) -> Void)?

    /// Closure to set blend mode for a source
    public var blendModeSetter: ((Int, String) -> Void)?

    /// Callback when effects change (for UI updates)
    public var onEffectChanged: (() -> Void)?

    // MARK: - Effects Session

    /// The effects session this manager uses for chain lookups
    /// Set by the owner (HypnographState, LivePlayer, etc.)
    public weak var session: EffectsSession?

    /// Global store for recently replaced/cleared chains (shared across modes).
    public weak var recentStore: RecentEffectChainsStore?

    // MARK: - Flash Solo

    /// When set, only render this source index (for flash solo preview)
    public var flashSoloIndex: Int?

    // MARK: - Effect Suspend

    /// When true, composition effect chain is bypassed (e.g., while holding 0 or 1-9 key in Montage)
    public var isCompositionEffectSuspended: Bool = false

    // MARK: - Blend Normalization

    /// Whether blend normalization is enabled (for A/B testing)
    public var isNormalizationEnabled: Bool = true {
        didSet {
            if oldValue != isNormalizationEnabled {
                onEffectChanged?()
            }
        }
    }

    /// Current normalization strategy (auto-selected by default)
    private var _normalizationStrategy: NormalizationStrategy?

    /// Cached blend mode analysis (recomputed when recipe changes)
    private var cachedAnalysis: BlendModeAnalysis?

    /// Get the active normalization strategy (auto-selects if not manually set)
    /// Returns NoNormalization if normalization is disabled
    public var normalizationStrategy: NormalizationStrategy {
        guard isNormalizationEnabled else {
            return NoNormalization()
        }
        if let manual = _normalizationStrategy {
            return manual
        }
        let analysis = currentBlendAnalysis
        return autoSelectNormalization(for: analysis)
    }

    /// Set a specific normalization strategy (nil = auto-select)
    public func setNormalizationStrategy(_ strategy: NormalizationStrategy?) {
        _normalizationStrategy = strategy
        onEffectChanged?()
    }

    /// Get current blend mode analysis for the recipe
    public var currentBlendAnalysis: BlendModeAnalysis {
        if let cached = cachedAnalysis {
            return cached
        }
        let blendModes = collectBlendModes()
        let analysis = analyzeBlendModes(blendModes)
        cachedAnalysis = analysis
        return analysis
    }

    /// Invalidate cached analysis (call when blend modes change)
    public func invalidateBlendAnalysis() {
        cachedAnalysis = nil
    }

    /// Collect all blend modes from the current composition.
    private func collectBlendModes() -> [String] {
        guard let composition = compositionProvider?() else { return [] }
        return composition.layers.enumerated().map { index, layer in
            if index == 0 {
                return BlendMode.sourceOver
            }
            return layer.blendMode ?? BlendMode.defaultMontage
        }
    }

    // MARK: - Init

    public init() {
        self.frameBuffer = FrameBuffer(maxFrames: 120)
    }

    init(frameBuffer: FrameBuffer) {
        self.frameBuffer = frameBuffer
    }

    // MARK: - Context Creation

    /// Create a render context for the current frame
    public func createContext(time: CMTime, outputSize: CGSize) -> RenderContext {
        createContext(frameIndex: frameIndex, time: time, outputSize: outputSize)
    }

    /// Create a render context for a specific frame index
    public func createContext(
        frameIndex: Int,
        time: CMTime,
        outputSize: CGSize,
        sourceIndex: Int? = nil
    ) -> RenderContext {
        RenderContext(
            frameIndex: frameIndex,
            time: time,
            outputSize: outputSize,
            frameBuffer: frameBuffer,
            sourceIndex: sourceIndex
        )
    }

    // MARK: - Composition Effect Chain

    /// Get the current composition effect chain name (for UI matching)
    public var compositionEffectName: String {
        compositionProvider?()?.effectChain.name ?? "None"
    }

    /// Get the current composition effect chain (for editing)
    public var compositionEffectChain: EffectChain {
        compositionProvider?()?.effectChain ?? EffectChain()
    }

    /// Set composition effect chain - the chain handles instantiation internally
    /// Copies the chain so the recipe has its own instance (not shared with library)
    public func setCompositionEffect(from chain: EffectChain) {
        compositionEffectChainSetter?(chain.clone())
        onEffectChanged?()
    }

    // MARK: - Effect Chain Management

    /// Update an effect's parameter in the recipe's effect chain
    /// - Parameters:
    ///   - layer: -1 for composition, 0+ for source index
    ///   - effectDefIndex: index of the effect in the chain
    ///   - key: parameter key
    ///   - value: new parameter value
    public func updateEffectParameter(for layer: Int, effectDefIndex: Int, key: String, value: AnyCodableValue) {
        guard let chain = effectChain(for: layer)?.clone(preserveRuntimeEffects: false) else { return }
        guard effectDefIndex >= 0, effectDefIndex < chain.effects.count else { return }

        var params = chain.effects[effectDefIndex].params ?? [:]
        params[key] = value
        chain.effects[effectDefIndex].params = params

        setEffectWorkingCopy(chain, for: layer)
    }

    /// Update a chain-level parameter (future: chain params like "strength")
    /// - Parameters:
    ///   - layer: -1 for composition, 0+ for source index
    ///   - key: parameter key
    ///   - value: new parameter value
    public func updateChainParameter(for layer: Int, key: String, value: AnyCodableValue) {
        guard let chain = effectChain(for: layer)?.clone(preserveRuntimeEffects: false) else { return }

        var params = chain.params ?? [:]
        params[key] = value
        chain.params = params

        setEffectWorkingCopy(chain, for: layer)
    }

    /// Add an effect to the recipe's effect chain for a layer
    /// - Parameters:
    ///   - layer: -1 for composition, 0+ for source index
    ///   - effectType: the type of effect to add (e.g. "IFrameCompressEffect")
    public func addEffectToChain(for layer: Int, effectType: String) {
        guard let chain = effectChain(for: layer)?.clone(preserveRuntimeEffects: false) else { return }

        let defaults = EffectRegistry.defaults(for: effectType)
        let newEffect = EffectDefinition(type: effectType, params: defaults)
        chain.effects.append(newEffect)

        setEffectWorkingCopy(chain, for: layer)
    }

    /// Remove an effect from the recipe's effect chain for a layer
    /// - Parameters:
    ///   - layer: -1 for composition, 0+ for source index
    ///   - effectDefIndex: index of the effect to remove
    public func removeEffectFromChain(for layer: Int, effectDefIndex: Int) {
        guard let chain = effectChain(for: layer)?.clone(preserveRuntimeEffects: false) else { return }
        guard effectDefIndex >= 0, effectDefIndex < chain.effects.count else { return }

        chain.effects.remove(at: effectDefIndex)

        setEffectWorkingCopy(chain, for: layer)
    }

    /// Update the chain name in the recipe
    /// - Parameters:
    ///   - layer: -1 for composition, 0+ for source index
    ///   - name: new name for the chain
    public func updateChainName(for layer: Int, name: String) {
        guard let chain = effectChain(for: layer)?.clone() else { return }
        chain.name = name
        setEffect(from: chain, for: layer)
    }

    /// Link/unlink the CURRENT chain to a template id (used for Update/Copy-to-Library actions).
    public func updateSourceTemplateId(for layer: Int, sourceTemplateId: UUID?) {
        guard let chain = effectChain(for: layer)?.clone() else { return }
        chain.sourceTemplateId = sourceTemplateId
        setEffect(from: chain, for: layer)
    }

    /// Reorder effects in the recipe's effect chain for a layer
    /// - Parameters:
    ///   - layer: -1 for composition, 0+ for source index
    ///   - fromIndex: source index
    ///   - toIndex: destination index
    public func reorderEffectsInChain(for layer: Int, fromIndex: Int, toIndex: Int) {
        guard let chain = effectChain(for: layer)?.clone(preserveRuntimeEffects: false) else { return }
        guard fromIndex >= 0, fromIndex < chain.effects.count else { return }
        guard toIndex >= 0, toIndex < chain.effects.count else { return }

        let effect = chain.effects.remove(at: fromIndex)
        chain.effects.insert(effect, at: toIndex)

        setEffectWorkingCopy(chain, for: layer)
    }

    /// Reset an effect's parameters to defaults in the recipe
    /// - Parameters:
    ///   - layer: -1 for composition, 0+ for source index
    ///   - effectDefIndex: index of the effect to reset
    public func resetEffectToDefaults(for layer: Int, effectDefIndex: Int) {
        guard let chain = effectChain(for: layer)?.clone(preserveRuntimeEffects: false) else { return }
        guard effectDefIndex >= 0, effectDefIndex < chain.effects.count else { return }

        let effectType = chain.effects[effectDefIndex].type

        // Get defaults from registry, preserve _enabled state
        var defaults = EffectRegistry.defaults(for: effectType)
        if let wasEnabled = chain.effects[effectDefIndex].params?["_enabled"] {
            defaults["_enabled"] = wasEnabled
        }

        chain.effects[effectDefIndex].params = defaults

        setEffectWorkingCopy(chain, for: layer)
    }

    /// Toggle effect enabled state in the recipe.
    public func setEffectEnabled(for layer: Int, effectDefIndex: Int, enabled: Bool) {
        updateEffectParameter(for: layer, effectDefIndex: effectDefIndex, key: "_enabled", value: .bool(enabled))
    }

    /// Toggle chain enabled state in the recipe without touching per-effect enabled flags.
    public func setChainEnabled(for layer: Int, enabled: Bool) {
        guard let chain = effectChain(for: layer)?.clone(preserveRuntimeEffects: false) else { return }
        var params = chain.params ?? [:]
        params["_enabled"] = .bool(enabled)
        chain.params = params
        setEffectWorkingCopy(chain, for: layer)
    }

    /// Randomize all parameters for an effect in the recipe.
    public func randomizeEffect(for layer: Int, effectDefIndex: Int) {
        guard let chain = effectChain(for: layer)?.clone(preserveRuntimeEffects: false) else { return }
        guard effectDefIndex >= 0, effectDefIndex < chain.effects.count else { return }

        let effectDef = chain.effects[effectDefIndex]
        let specs = EffectRegistry.parameterSpecs(for: effectDef.type)
        var randomParams: [String: AnyCodableValue] = [:]

        for (key, spec) in specs {
            randomParams[key] = spec.randomValue()
        }

        // Preserve _enabled state (default to true if absent)
        randomParams["_enabled"] = effectDef.params?["_enabled"] ?? .bool(true)

        chain.effects[effectDefIndex].params = randomParams
        setEffectWorkingCopy(chain, for: layer)
    }

    /// Re-apply active effects using fresh instances from the session.
    /// Called when effects config changes to apply parameter updates immediately.
    public func reapplyActiveEffects() {
        guard let composition = compositionProvider?() else { return }

        // Get the chain list from session (required) - use thread-safe snapshot
        guard let session = session else {
            print("⚠️ EffectManager.reapplyActiveEffects: No session available")
            return
        }
        let availableChains = session.chainsSnapshot

        // Re-apply composition effect chain by name from stored chain
        let currentName = composition.effectChain.name
        if let freshChain = availableChains.first(where: { $0.name == currentName }) {
            // Replace with fresh chain - it will re-instantiate effects on next apply()
            compositionEffectChainSetter?(freshChain.clone())
            print("🔄 Reapplied composition effect: \(currentName ?? "unnamed")")
        }

        // Re-apply per-layer effects by name from stored chains
        for (index, layer) in composition.layers.enumerated() {
            let currentLayerName = layer.effectChain.name
            if let freshChain = availableChains.first(where: { $0.name == currentLayerName }) {
                sourceEffectChainSetter?(index, freshChain.clone())
                print("🔄 Reapplied layer \(index) effect: \(currentLayerName ?? "unnamed")")
            }
        }

        onEffectChanged?()
    }

    // MARK: - Per-Layer Effects (reads from composition layers)

    /// Get the source effect chain name (for UI matching)
    public func sourceEffectName(for sourceIndex: Int) -> String {
        guard let composition = compositionProvider?(),
              sourceIndex >= 0,
              sourceIndex < composition.layers.count else {
            return "None"
        }
        return composition.layers[sourceIndex].effectChain.name ?? "None"
    }

    /// Set source effect from a chain - the chain handles instantiation internally
    /// Copies the chain so the source has its own instance (not shared with library)
    public func setSourceEffect(from chain: EffectChain, for sourceIndex: Int) {
        sourceEffectChainSetter?(sourceIndex, chain.clone())
        onEffectChanged?()
    }

    /// Clear effect for a layer (-1 = composition, 0+ = source index)
    public func clearEffect(for layer: Int) {
        clearEffect(for: layer, captureToRecent: true)
    }

    private func captureChainToRecent(_ chain: EffectChain) {
        guard !chain.effects.isEmpty else { return }
        let store = recentStore
        let snapshot = chain.clone()
        Task { @MainActor in
            store?.addToFront(snapshot)
        }
    }

    private func clearEffect(for layer: Int, captureToRecent: Bool) {
        if captureToRecent, let existing = effectChain(for: layer) {
            captureChainToRecent(existing)
        }
        if layer == -1 {
            compositionEffectChainSetter?(EffectChain())
        } else {
            sourceEffectChainSetter?(layer, EffectChain())
        }
        onEffectChanged?()
    }

    /// Get a source's effect chain (for editing)
    public func sourceEffectChain(for sourceIndex: Int) -> EffectChain? {
        guard let composition = compositionProvider?(),
              sourceIndex >= 0,
              sourceIndex < composition.layers.count else {
            return nil
        }
        return composition.layers[sourceIndex].effectChain
    }

    // MARK: - Unified Layer API (layer -1 = composition, 0+ = source)

    /// Get effect name for a layer (-1 = composition, 0+ = source index)
    public func effectName(for layer: Int) -> String {
        if layer == -1 {
            return compositionEffectName
        }
        return sourceEffectName(for: layer)
    }

    /// Get effect chain for a layer (-1 = composition, 0+ = source index)
    public func effectChain(for layer: Int) -> EffectChain? {
        if layer == -1 {
            return compositionEffectChain
        }
        return sourceEffectChain(for: layer)
    }

    /// Set effect from a chain for a layer (-1 = composition, 0+ = source index)
    /// This sets CURRENT (the recipe-owned working copy) to the provided chain.
    public func setEffect(from chain: EffectChain?, for layer: Int) {
        if layer == -1 {
            setCompositionEffect(from: chain ?? EffectChain())
        } else {
            setSourceEffect(from: chain ?? EffectChain(), for: layer)
        }
    }

    /// Apply an already-owned working copy without an additional clone hop.
    private func setEffectWorkingCopy(_ chain: EffectChain, for layer: Int) {
        if layer == -1 {
            compositionEffectChainSetter?(chain)
        } else {
            sourceEffectChainSetter?(layer, chain)
        }
        onEffectChanged?()
    }

    /// Replace CURRENT with a snapshot/template, capturing the old chain into RECENT.
    /// This is the shared implementation behind applying a template or a recent entry.
    public func applyChainSnapshot(_ chain: EffectChain?, sourceTemplateId: UUID?, to layer: Int) {
        if let existing = effectChain(for: layer) {
            captureChainToRecent(existing)
        }

        if let chain {
            let recipeChain = EffectChain(duplicating: chain, sourceTemplateId: sourceTemplateId)
            setEffect(from: recipeChain, for: layer)
        } else {
            clearEffect(for: layer, captureToRecent: false)
        }
    }

    /// Apply a library template to CURRENT without churning IDs during edits.
    /// - If template is non-nil, creates a new recipe-owned instance with a new id and links it via `sourceTemplateId`.
    /// - If template is nil, clears the chain on the recipe.
    public func applyTemplate(_ template: EffectChain?, to layer: Int) {
        applyChainSnapshot(template, sourceTemplateId: template?.id, to: layer)
    }

    /// Cycle effect for a layer (-1 = composition, 0+ = source index)
    /// direction: 1 = forward, -1 = backward
    public func cycleEffect(for layer: Int, direction: Int = 1) {
        // Clear frame buffer and reset frame counter so new effect starts fresh
        frameBuffer.clear()
        resetFrameIndex()

        // Get chains from session (required) - use thread-safe snapshot
        guard let session = session else {
            print("⚠️ EffectManager.cycleEffect: No session available")
            return
        }
        let chains = session.chainsSnapshot

        let currentName = effectName(for: layer)
        let currentIndex = chains.firstIndex { $0.name == currentName } ?? -1

        // Cycle through effects: -1 (None) -> 0 -> 1 -> ... -> count-1 -> -1
        let effectCount = chains.count
        let totalStates = effectCount + 1  // +1 for "None"

        // Convert to 0-based index where 0 = None, 1+ = effects
        let current0Based = currentIndex + 1
        let next0Based = (current0Based + direction + totalStates) % totalStates
        let nextIndex = next0Based - 1  // Back to -1 based

        applyTemplate(nextIndex >= 0 ? chains[nextIndex] : nil, to: layer)
    }

    public func clearFrameBuffer() {
        print("🔄 EffectManager: clearFrameBuffer() - clearing \(frameBuffer.frameCount) frames")
        frameBuffer.clear()
        resetFrameIndex()

        // Reset all effects that have internal state (e.g. IFrameCompressEffect, text overlays)
        // Important: Do this BEFORE the recipe clears effects, because effects may be preserved
        if let composition = compositionProvider?() {
            composition.effectChain.reset()
            for layer in composition.layers {
                layer.effectChain.reset()
            }
        }
    }

    /// Record a frame into the temporal buffer (used by compositors)
    public func recordFrame(_ image: CIImage, at time: CMTime) {
        frameBuffer.addFrame(image, at: time)
    }

    // MARK: - Frame Buffer Preloading

    /// Preload frame buffer for a video asset (if temporal effects need it)
    /// - Parameters:
    ///   - asset: The video asset to preload from
    ///   - startTime: Start time for preroll
    public func preloadFrameBuffer(from asset: AVAsset, startTime: CMTime = .zero) async {
        _ = await FrameBufferPreloader.preload(
            asset: asset,
            frameBuffer: frameBuffer,
            effectManager: self,
            startTime: startTime
        )
    }

    /// Preload frame buffer for a still image (if temporal effects need it)
    /// - Parameter image: The still image to prefill with
    public func preloadFrameBuffer(from image: CIImage) {
        _ = FrameBufferPreloader.preload(
            image: image,
            frameBuffer: frameBuffer,
            effectManager: self
        )
    }

    // MARK: - Blend Modes (reads from hypnogram layers)

    public func blendMode(for sourceIndex: Int) -> String {
        // Source 0 is always source-over (base layer)
        if sourceIndex == 0 {
            return BlendMode.sourceOver
        }
        // Read from the recipe (single source of truth)
        guard let composition = compositionProvider?(),
              sourceIndex >= 0,
              sourceIndex < composition.layers.count else {
            return BlendMode.defaultMontage
        }
        return composition.layers[sourceIndex].blendMode ?? BlendMode.defaultMontage
    }

    public func setBlendMode(_ mode: String, for sourceIndex: Int, silent: Bool = false) {
        blendModeSetter?(sourceIndex, mode)
        invalidateBlendAnalysis()  // Blend modes changed, recalculate analysis
        if !silent {
            onEffectChanged?()
        }
    }

    public func cycleBlendMode(for sourceIndex: Int) {
        // Don't cycle source 0 - it's always source-over
        guard sourceIndex > 0 else { return }

        let currentMode = blendMode(for: sourceIndex)
        let currentIndex = BlendMode.all.firstIndex(of: currentMode) ?? 0
        let nextIndex = (currentIndex + 1) % BlendMode.all.count
        setBlendMode(BlendMode.all[nextIndex], for: sourceIndex)
    }

    // MARK: - Blend Normalization Helpers

    /// Get compensated opacity for a layer (for use during compositing)
    public func compensatedOpacity(
        layerIndex: Int,
        totalLayers: Int,
        blendMode: String
    ) -> CGFloat {
        let analysis = currentBlendAnalysis
        return normalizationStrategy.opacityForLayer(
            index: layerIndex,
            totalLayers: totalLayers,
            blendMode: blendMode,
            analysis: analysis
        )
    }

    /// Apply post-composition normalization (call after all layers blended, before composition effect chain)
    public func applyNormalization(to image: CIImage) -> CIImage {
        let analysis = currentBlendAnalysis
        return normalizationStrategy.normalizeComposite(image, analysis: analysis)
    }

    // MARK: - Flash Solo

    /// Set flash solo to show only the specified source index
    public func setFlashSolo(_ sourceIndex: Int?) {
        // Only trigger effect change if the value actually changed
        guard flashSoloIndex != sourceIndex else { return }
        flashSoloIndex = sourceIndex
        onEffectChanged?()
    }

    /// Check if a given source should be visible (respects flash solo)
    public func shouldRenderSource(at sourceIndex: Int) -> Bool {
        guard let soloIndex = flashSoloIndex else {
            return true  // No flash solo active, render all
        }
        return sourceIndex == soloIndex
    }
}
