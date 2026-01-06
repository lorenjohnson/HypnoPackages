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
    let frameBuffer = FrameBuffer(maxFrames: 120)

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

    /// Create a manager for export with a frozen recipe
    /// Uses same code paths as preview but with isolated state
    public static func forExport(recipe: HypnogramRecipe) -> EffectManager {
        let manager = EffectManager()
        manager.recipeProvider = { recipe }
        // No setters needed - export is read-only
        // flashSoloIndex stays nil - export renders all layers
        return manager
    }

    /// Get the maximum lookback required by any effect (global or per-source)
    public var maxRequiredLookback: Int {
        guard let recipe = recipeProvider?() else { return 0 }

        // Check global effect chain
        let globalMax = recipe.effectChain.maxRequiredLookback

        // Check per-source effect chains
        let sourceMax = recipe.sources.map { $0.effectChain.maxRequiredLookback }.max() ?? 0

        return max(globalMax, sourceMax)
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

    /// Closure to get the current recipe (injected by RecipeManager)
    public var recipeProvider: (() -> HypnogramRecipe?)?

    /// Closure to set global effect chain on the recipe
    public var globalEffectChainSetter: ((EffectChain) -> Void)?

    /// Closure to set per-source effect chain on the recipe
    public var sourceEffectChainSetter: ((Int, EffectChain) -> Void)?

    /// Closure to set blend mode for a source
    public var blendModeSetter: ((Int, String) -> Void)?

    /// Callback when effects change (for UI updates)
    public var onEffectChanged: (() -> Void)?

    // MARK: - Effects Session

    /// The effects session this manager uses for chain lookups
    /// Set by the owner (HypnographState, LivePlayer, etc.)
    public weak var session: EffectsSession?

    // MARK: - Flash Solo

    /// When set, only render this source index (for flash solo preview)
    public var flashSoloIndex: Int?

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

    /// Collect all blend modes from current recipe
    private func collectBlendModes() -> [String] {
        guard let recipe = recipeProvider?() else { return [] }
        return recipe.sources.enumerated().map { index, source in
            if index == 0 {
                return BlendMode.sourceOver
            }
            return source.blendMode ?? BlendMode.defaultMontage
        }
    }

    // MARK: - Init

    public init() {}

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

    // MARK: - Global Effects (reads from recipe)

    /// Get the current global effect chain name (for UI matching)
    public var globalEffectName: String {
        recipeProvider?()?.effectChain.name ?? "None"
    }

    /// Get the current global effect chain (for editing)
    public var globalEffectChain: EffectChain {
        recipeProvider?()?.effectChain ?? EffectChain()
    }

    /// Set global effect from an effect chain - the chain handles instantiation internally
    /// Copies the chain so the recipe has its own instance (not shared with library)
    public func setGlobalEffect(from chain: EffectChain) {
        globalEffectChainSetter?(chain.copy())
        onEffectChanged?()
    }

    // MARK: - Effect Chain Management

    /// Update an effect's parameter in the recipe's effect chain
    /// - Parameters:
    ///   - layer: -1 for global, 0+ for source index
    ///   - effectDefIndex: index of the effect in the chain
    ///   - key: parameter key
    ///   - value: new parameter value
    public func updateEffectParameter(for layer: Int, effectDefIndex: Int, key: String, value: AnyCodableValue) {
        guard var chain = effectChain(for: layer) else { return }
        guard effectDefIndex >= 0, effectDefIndex < chain.effects.count else { return }

        var params = chain.effects[effectDefIndex].params ?? [:]
        params[key] = value
        chain.effects[effectDefIndex].params = params

        setEffect(from: chain, for: layer)
    }

    /// Update a chain-level parameter (future: chain params like "strength")
    /// - Parameters:
    ///   - layer: -1 for global, 0+ for source index
    ///   - key: parameter key
    ///   - value: new parameter value
    public func updateChainParameter(for layer: Int, key: String, value: AnyCodableValue) {
        guard var chain = effectChain(for: layer) else { return }

        var params = chain.params ?? [:]
        params[key] = value
        chain.params = params

        setEffect(from: chain, for: layer)
    }

    /// Add an effect to the recipe's effect chain for a layer
    /// - Parameters:
    ///   - layer: -1 for global, 0+ for source index
    ///   - effectType: the type of effect to add (e.g. "DatamoshMetalEffect")
    public func addEffectToChain(for layer: Int, effectType: String) {
        guard var chain = effectChain(for: layer) else { return }

        let defaults = EffectRegistry.defaults(for: effectType)
        let newEffect = EffectDefinition(type: effectType, params: defaults)
        chain.effects.append(newEffect)

        setEffect(from: chain, for: layer)
    }

    /// Remove an effect from the recipe's effect chain for a layer
    /// - Parameters:
    ///   - layer: -1 for global, 0+ for source index
    ///   - effectDefIndex: index of the effect to remove
    public func removeEffectFromChain(for layer: Int, effectDefIndex: Int) {
        guard var chain = effectChain(for: layer) else { return }
        guard effectDefIndex >= 0, effectDefIndex < chain.effects.count else { return }

        chain.effects.remove(at: effectDefIndex)

        setEffect(from: chain, for: layer)
    }

    /// Update the chain name in the recipe
    /// - Parameters:
    ///   - layer: -1 for global, 0+ for source index
    ///   - name: new name for the chain
    public func updateChainName(for layer: Int, name: String) {
        guard var chain = effectChain(for: layer) else { return }
        chain.name = name
        setEffect(from: chain, for: layer)
    }

    /// Reorder effects in the recipe's effect chain for a layer
    /// - Parameters:
    ///   - layer: -1 for global, 0+ for source index
    ///   - fromIndex: source index
    ///   - toIndex: destination index
    public func reorderEffectsInChain(for layer: Int, fromIndex: Int, toIndex: Int) {
        guard var chain = effectChain(for: layer) else { return }
        guard fromIndex >= 0, fromIndex < chain.effects.count else { return }
        guard toIndex >= 0, toIndex < chain.effects.count else { return }

        let effect = chain.effects.remove(at: fromIndex)
        chain.effects.insert(effect, at: toIndex)

        setEffect(from: chain, for: layer)
    }

    /// Reset an effect's parameters to defaults in the recipe
    /// - Parameters:
    ///   - layer: -1 for global, 0+ for source index
    ///   - effectDefIndex: index of the effect to reset
    public func resetEffectToDefaults(for layer: Int, effectDefIndex: Int) {
        guard var chain = effectChain(for: layer) else { return }
        guard effectDefIndex >= 0, effectDefIndex < chain.effects.count else { return }

        let effectType = chain.effects[effectDefIndex].type

        // Get defaults from registry, preserve _enabled state
        var defaults = EffectRegistry.defaults(for: effectType)
        if let wasEnabled = chain.effects[effectDefIndex].params?["_enabled"] {
            defaults["_enabled"] = wasEnabled
        }

        chain.effects[effectDefIndex].params = defaults

        setEffect(from: chain, for: layer)
    }

    /// Re-apply active effects using fresh instances from the session.
    /// Called when effects config changes to apply parameter updates immediately.
    public func reapplyActiveEffects() {
        guard let recipe = recipeProvider?() else { return }

        // Get the chain list from session (required) - use thread-safe snapshot
        guard let session = session else {
            print("⚠️ EffectManager.reapplyActiveEffects: No session available")
            return
        }
        let availableChains = session.chainsSnapshot

        // Re-apply global effect by name from stored chain
        let currentName = recipe.effectChain.name
        if let freshChain = availableChains.first(where: { $0.name == currentName }) {
            // Replace with fresh chain - it will re-instantiate effects on next apply()
            globalEffectChainSetter?(freshChain.copy())
            print("🔄 Reapplied global effect: \(currentName ?? "unnamed")")
        }

        // Re-apply per-source effects by name from stored chains
        for (index, source) in recipe.sources.enumerated() {
            let currentSourceName = source.effectChain.name
            if let freshChain = availableChains.first(where: { $0.name == currentSourceName }) {
                sourceEffectChainSetter?(index, freshChain.copy())
                print("🔄 Reapplied source \(index) effect: \(currentSourceName ?? "unnamed")")
            }
        }

        onEffectChanged?()
    }

    // MARK: - Per-Source Effects (reads from recipe sources)

    /// Get the source effect chain name (for UI matching)
    public func sourceEffectName(for sourceIndex: Int) -> String {
        guard let recipe = recipeProvider?(),
              sourceIndex >= 0,
              sourceIndex < recipe.sources.count else {
            return "None"
        }
        return recipe.sources[sourceIndex].effectChain.name ?? "None"
    }

    /// Set source effect from a chain - the chain handles instantiation internally
    /// Copies the chain so the source has its own instance (not shared with library)
    public func setSourceEffect(from chain: EffectChain, for sourceIndex: Int) {
        sourceEffectChainSetter?(sourceIndex, chain.copy())
        onEffectChanged?()
    }

    /// Clear effect for a layer (-1 = global, 0+ = source index)
    public func clearEffect(for layer: Int) {
        if layer == -1 {
            globalEffectChainSetter?(EffectChain())
        } else {
            sourceEffectChainSetter?(layer, EffectChain())
        }
        onEffectChanged?()
    }

    /// Get a source's effect chain (for editing)
    public func sourceEffectChain(for sourceIndex: Int) -> EffectChain? {
        guard let recipe = recipeProvider?(),
              sourceIndex >= 0,
              sourceIndex < recipe.sources.count else {
            return nil
        }
        return recipe.sources[sourceIndex].effectChain
    }

    // MARK: - Unified Layer API (layer -1 = global, 0+ = source)

    /// Get effect name for a layer (-1 = global, 0+ = source index)
    public func effectName(for layer: Int) -> String {
        if layer == -1 {
            return globalEffectName
        }
        return sourceEffectName(for: layer)
    }

    /// Get effect chain for a layer (-1 = global, 0+ = source index)
    public func effectChain(for layer: Int) -> EffectChain? {
        if layer == -1 {
            return globalEffectChain
        }
        return sourceEffectChain(for: layer)
    }

    /// Set effect from a chain for a layer (-1 = global, 0+ = source index)
    /// This is the preferred method for selecting effects from the library
    public func setEffect(from chain: EffectChain?, for layer: Int) {
        if layer == -1 {
            setGlobalEffect(from: chain ?? EffectChain())
        } else {
            setSourceEffect(from: chain ?? EffectChain(), for: layer)
        }
    }

    /// Cycle effect for a layer (-1 = global, 0+ = source index)
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

        setEffect(from: nextIndex >= 0 ? chains[nextIndex] : nil, for: layer)
    }

    // MARK: - Application

    /// Apply recipe effects to the final composed image
    public func applyGlobal(to context: inout RenderContext, image: CIImage) -> CIImage {
        // Global effect is not tied to a particular source.
        context.sourceIndex = nil

        // Skip global effects during flash solo - show raw source
        if flashSoloIndex != nil {
            frameBuffer.addFrame(image, at: context.time)
            return image
        }

        guard let recipe = recipeProvider?(), recipe.effectChain.hasEnabledEffects else {
            // Even if no effect, still update buffer for future use
            frameBuffer.addFrame(image, at: context.time)
            return image
        }

        // Apply all effects in the chain
        var result = recipe.effectChain.apply(to: image, context: &context)

        // Update frame buffer with processed result so temporal effects see prior effects
        frameBuffer.addFrame(result, at: context.time)

        return result
    }

    /// Apply per-source effects to a single source image (before compositing)
    public func applyToSource(sourceIndex: Int, context: inout RenderContext, image: CIImage) -> CIImage {
        guard let recipe = recipeProvider?(),
              sourceIndex >= 0,
              sourceIndex < recipe.sources.count else {
            return image
        }

        let effectChain = recipe.sources[sourceIndex].effectChain
        guard effectChain.hasEnabledEffects else { return image }

        // Mark which source is being processed so effects can branch if they want.
        context.sourceIndex = sourceIndex

        return effectChain.apply(to: image, context: &context)
    }

    public func clearFrameBuffer() {
        print("🔄 EffectManager: clearFrameBuffer() - clearing \(frameBuffer.frameCount) frames")
        frameBuffer.clear()
        resetFrameIndex()

        // Reset all effects that have internal state (HoldFrameEffect, DatamoshEffect, etc.)
        // Important: Do this BEFORE the recipe clears effects, because effects may be preserved
        if let recipe = recipeProvider?() {
            recipe.effectChain.reset()
            for source in recipe.sources {
                source.effectChain.reset()
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

    // MARK: - Blend Modes (reads from recipe sources)

    public func blendMode(for sourceIndex: Int) -> String {
        // Source 0 is always source-over (base layer)
        if sourceIndex == 0 {
            return BlendMode.sourceOver
        }
        // Read from the recipe (single source of truth)
        guard let recipe = recipeProvider?(),
              sourceIndex >= 0,
              sourceIndex < recipe.sources.count else {
            return BlendMode.defaultMontage
        }
        return recipe.sources[sourceIndex].blendMode ?? BlendMode.defaultMontage
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

    /// Apply post-composition normalization (call after all layers blended, before global effects)
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
