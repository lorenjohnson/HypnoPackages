//
//  AppKit.swift
//  HypnoCore
//
//  Extensions for AppKit types.

import AppKit

// MARK: - NSColor

public extension NSColor {
    /// Create an NSColor from a hex string (e.g., "#FFFFFF" or "FF0000")
    static func fromHex(_ hex: String) -> NSColor? {
        var hexSanitized = hex.trimmingCharacters(in: .whitespacesAndNewlines)
        hexSanitized = hexSanitized.replacingOccurrences(of: "#", with: "")

        guard hexSanitized.count == 6 else { return nil }

        var rgb: UInt64 = 0
        Scanner(string: hexSanitized).scanHexInt64(&rgb)

        let r = CGFloat((rgb & 0xFF0000) >> 16) / 255.0
        let g = CGFloat((rgb & 0x00FF00) >> 8) / 255.0
        let b = CGFloat(rgb & 0x0000FF) / 255.0

        return NSColor(calibratedRed: r, green: g, blue: b, alpha: 1.0)
    }

    /// Convert to hex string (e.g., "#FFFFFF")
    func toHex() -> String {
        guard let rgbColor = usingColorSpace(.sRGB) else { return "#FFFFFF" }
        let r = Int(rgbColor.redComponent * 255)
        let g = Int(rgbColor.greenComponent * 255)
        let b = Int(rgbColor.blueComponent * 255)
        return String(format: "#%02X%02X%02X", r, g, b)
    }
}

// MARK: - NSWindow

/// Legacy "borderless fullscreen" window mode.
/// This creates a fullscreen window that stays on the current desktop/Space rather than
/// creating a new Space like native macOS fullscreen. We decided to use native fullscreen
/// for general use, but this is kept in case we want to return to this approach later.
/// Currently used by Hypnograph for its dedicated display mode.
public extension NSWindow {
    /// Configure the window as a borderless fullscreen window.
    /// This removes all chrome and fills the specified screen while staying on the desktop.
    func makeBorderlessHypnoWindow(on screen: NSScreen) {
        let fullFrame = screen.frame

        styleMask.remove(.titled)
        styleMask.remove(.closable)
        styleMask.remove(.miniaturizable)
        styleMask.remove(.resizable)

        collectionBehavior = [.fullScreenNone, .canJoinAllSpaces]

        titleVisibility = .hidden
        titlebarAppearsTransparent = true

        standardWindowButton(.closeButton)?.isHidden = true
        standardWindowButton(.miniaturizeButton)?.isHidden = true
        standardWindowButton(.zoomButton)?.isHidden = true

        isOpaque = true
        backgroundColor = .black
        level = .normal

        setFrame(fullFrame, display: true, animate: false)
        isMovable = false
    }
}
