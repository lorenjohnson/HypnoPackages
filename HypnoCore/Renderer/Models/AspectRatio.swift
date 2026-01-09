//
//  AspectRatio.swift
//  HypnoRenderer
//
//  Represents an aspect ratio for output sizing.
//

import CoreGraphics
#if canImport(AppKit)
import AppKit
#endif

// MARK: - AspectRatio

/// Represents an aspect ratio (width / height).
/// Can be parsed from decimal (2.35) or ratio string ("16:9").
/// Special case: "fill" means use view's native aspect ratio (no letterboxing).
public struct AspectRatio: Codable, Equatable, CustomStringConvertible, Hashable {
    /// The ratio as width / height (e.g., 16:9 = 1.778)
    /// For .fillScreen, this is 0 (sentinel value - actual ratio computed at runtime)
    public let value: CGFloat

    /// Original string representation for display
    public let displayString: String

    /// Whether this is the "fill window" sentinel
    public var isFillWindow: Bool { displayString == "fill" }

    // MARK: - Common Presets

    /// Fill window - scales content to fill the view (may crop if aspect ratios differ)
    public static let fillWindow = AspectRatio(value: 0, displayString: "fill")

    public static let ratio16x9 = AspectRatio(value: 16.0 / 9.0, displayString: "16:9")
    public static let ratio4x3 = AspectRatio(value: 4.0 / 3.0, displayString: "4:3")
    public static let ratio21x9 = AspectRatio(value: 21.0 / 9.0, displayString: "21:9")
    public static let ratio1x1 = AspectRatio(value: 1.0, displayString: "1:1")
    public static let ratio9x16 = AspectRatio(value: 9.0 / 16.0, displayString: "9:16")  // Portrait
    public static let ratio235 = AspectRatio(value: 2.35, displayString: "2.35:1")  // Cinemascope
    public static let ratio185 = AspectRatio(value: 1.85, displayString: "1.85:1")  // Theatrical

    public static let presets: [AspectRatio] = [
        .ratio16x9, .ratio4x3, .ratio21x9, .ratio1x1, .ratio9x16, .ratio235, .ratio185
    ]

    /// Presets shown in the menu (subset of all presets, most common use cases)
    public static let menuPresets: [AspectRatio] = [
        .fillWindow, .ratio16x9, .ratio9x16, .ratio4x3, .ratio1x1
    ]

    /// Label for menu display with orientation hint
    public var menuLabel: String {
        switch displayString {
        case "fill": return "Fill Window"
        case "16:9": return "16:9 (Landscape)"
        case "9:16": return "9:16 (Portrait)"
        case "4:3": return "4:3"
        case "1:1": return "1:1 (Square)"
        default: return displayString
        }
    }

    /// Get the effective aspect ratio, resolving fillWindow to container's ratio
    public func effectiveValue(for containerSize: CGSize) -> CGFloat {
        if isFillWindow {
            guard containerSize.height > 0 else { return 16.0 / 9.0 }
            return containerSize.width / containerSize.height
        }
        return value
    }

    /// Get the current main screen's aspect ratio
    public static func screenAspectRatio() -> CGFloat {
        #if canImport(AppKit)
        if let screen = NSScreen.main {
            let frame = screen.frame
            guard frame.height > 0 else { return 16.0 / 9.0 }
            return frame.width / frame.height
        }
        #endif
        return 16.0 / 9.0  // Fallback
    }
    
    // MARK: - Initialization
    
    public init(value: CGFloat, displayString: String) {
        self.value = value
        self.displayString = displayString
    }
    
    /// Parse from a string like "16:9", "2.35", "2.35:1", or "fill"
    public static func parse(_ string: String) -> AspectRatio? {
        let trimmed = string.trimmingCharacters(in: .whitespaces)

        // Handle fill window sentinel
        if trimmed == "fill" {
            return .fillWindow
        }

        // Try ratio format (e.g., "16:9", "2.35:1")
        if trimmed.contains(":") {
            let parts = trimmed.split(separator: ":")
            guard parts.count == 2,
                  let width = Double(parts[0]),
                  let height = Double(parts[1]),
                  height > 0 else {
                return nil
            }
            return AspectRatio(value: CGFloat(width / height), displayString: trimmed)
        }

        // Try decimal format (e.g., "2.35", "1.778")
        if let decimal = Double(trimmed), decimal > 0 {
            return AspectRatio(value: CGFloat(decimal), displayString: trimmed)
        }

        return nil
    }
    
    // MARK: - Codable
    
    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let string = try container.decode(String.self)
        
        guard let parsed = AspectRatio.parse(string) else {
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "Invalid aspect ratio format: \(string)"
            )
        }
        
        self.value = parsed.value
        self.displayString = parsed.displayString
    }
    
    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(displayString)
    }
    
    // MARK: - CustomStringConvertible

    public var description: String { displayString }
}
