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
