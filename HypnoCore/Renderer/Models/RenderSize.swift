//
//  RenderSize.swift
//  HypnoRenderer
//
//  Size calculation utilities for rendering.
//

import CoreGraphics

// MARK: - Render Size Calculations

/// Calculate render size for an aspect ratio to fit within a container.
/// Returns the largest size with the given aspect ratio that fits in the container.
/// For fillWindow, returns the container size directly.
public func renderSize(aspectRatio: AspectRatio, fitting containerSize: CGSize) -> CGSize {
    // Fill window - use container size directly (no letterboxing)
    if aspectRatio.isFillWindow {
        return containerSize
    }

    let containerAspect = containerSize.width / containerSize.height

    if aspectRatio.value > containerAspect {
        // Wider than container - fit to width, letterbox top/bottom
        let width = containerSize.width
        let height = width / aspectRatio.value
        return CGSize(width: width, height: height)
    } else {
        // Taller than container - fit to height, pillarbox left/right
        let height = containerSize.height
        let width = height * aspectRatio.value
        return CGSize(width: width, height: height)
    }
}

/// Calculate render size for an aspect ratio constrained by maxDimension.
/// maxDimension constrains height for landscape, width for portrait.
/// For fillWindow, uses the current screen's aspect ratio for export.
public func renderSize(aspectRatio: AspectRatio, maxDimension: Int) -> CGSize {
    let maxDim = CGFloat(maxDimension)

    // For fillWindow export, use screen's aspect ratio as reasonable default
    let effectiveValue = aspectRatio.isFillWindow
        ? AspectRatio.screenAspectRatio()
        : aspectRatio.value

    if effectiveValue >= 1.0 {
        // Landscape or square - height is the constraining dimension
        let height = maxDim
        let width = round(height * effectiveValue)
        return CGSize(width: width, height: height)
    } else {
        // Portrait - width is the constraining dimension
        let width = maxDim
        let height = round(width / effectiveValue)
        return CGSize(width: width, height: height)
    }
}
