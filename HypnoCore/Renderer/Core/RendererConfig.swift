//
//  RendererConfig.swift
//  HypnoEffects
//
//  Renderer configuration constants.
//

import Foundation

/// Renderer configuration
enum RendererConfig {
    /// Whether to preroll the frame buffer before playback for temporal effects.
    /// When enabled, extracts frames from video before playback starts so temporal
    /// effects (Datamosh, GhostBlur, etc.) work immediately.
    ///
    /// Trade-off: Playback may start slightly into the clip (by requiredLookback frames).
    /// For a 30-frame lookback at 30fps, this is 1 second into the clip.
    ///
    /// Set to false to always start at the beginning (effects will build up naturally).
    static let prerollEnabled: Bool = true
}
