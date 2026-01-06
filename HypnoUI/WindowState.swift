//
//  WindowState.swift
//  HypnoAppShell
//
//  Unified window visibility state with clean screen support.
//  Tab toggles clean screen mode, hiding all windows temporarily.
//
//  Generic dictionary-based system: windows self-identify with string IDs.
//

import Foundation

/// Manages visibility state for all windows/overlays using generic string keys
public struct WindowState: Codable {

    // MARK: - Storage

    /// Generic dictionary-based storage for window visibility
    /// Keys are whatever string IDs windows choose to use
    private var windowVisibility: [String: Bool] = [:]

    /// When true, all windows are hidden regardless of their individual visibility states
    public var isCleanScreen: Bool = false

    public init() {}

    // MARK: - Window Registration

    /// Register a window so it's known to the system
    /// Windows should call this on first appearance (e.g., in view's onAppear)
    public mutating func register(_ windowID: String, defaultVisible: Bool = false) {
        // Only register if not already known
        if windowVisibility[windowID] == nil {
            windowVisibility[windowID] = defaultVisible
        }
    }

    // MARK: - Window Access

    /// Check if a window is visible (respects clean screen)
    public func isVisible(_ windowID: String) -> Bool {
        if isCleanScreen { return false }
        return windowVisibility[windowID] ?? false
    }

    /// Toggle a window's visibility
    /// - Returns: true if the toggle was consumed by exiting clean screen
    @discardableResult
    public mutating func toggle(_ windowID: String) -> Bool {
        if isCleanScreen {
            isCleanScreen = false
            return true  // Consumed
        }
        windowVisibility[windowID] = !(windowVisibility[windowID] ?? false)
        return false
    }

    /// Set a window's visibility directly
    public mutating func set(_ windowID: String, visible: Bool) {
        if visible && isCleanScreen {
            isCleanScreen = false
        }
        windowVisibility[windowID] = visible
    }

    /// Toggle clean screen mode
    /// If exiting clean screen and no windows are visible, shows all registered windows
    public mutating func toggleCleanScreen() {
        if isCleanScreen {
            // Exiting clean screen
            isCleanScreen = false

            // If no windows are currently visible, show all registered windows as a "reset"
            if !hasAnyWindowVisible {
                for windowID in windowVisibility.keys {
                    windowVisibility[windowID] = true
                }
            }
        } else {
            // Entering clean screen (only if something is visible)
            if hasAnyWindowVisible {
                isCleanScreen = true
            }
        }
    }

    /// Whether any window is currently visible
    public var hasAnyWindowVisible: Bool {
        windowVisibility.values.contains(true)
    }
}
