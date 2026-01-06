//
//  ParameterSpec.swift
//  Hypnograph
//
//  Parameter specification for effect parameters.
//  Defines type, default value, and constraints for each parameter.
//  Extracted from RenderHooks.swift as part of effects architecture refactor.
//

import Foundation

/// Metadata for a single effect parameter - defines type, range, and default value.
/// Each effect declares its parameters using this, making the effect the source of truth.
public enum ParameterSpec: Equatable {
    case double(default: Double, range: ClosedRange<Double>)
    case float(default: Float, range: ClosedRange<Float>)
    case int(default: Int, range: ClosedRange<Int>)
    case bool(default: Bool)
    /// Choice parameter: stores as string, displays as dropdown
    /// - default: the default choice key
    /// - options: ordered list of (key, displayLabel) pairs
    case choice(default: String, options: [(key: String, label: String)])
    /// Color parameter: stores as hex string (e.g., "#FFFFFF"), displays as color picker
    case color(default: String)
    /// File picker: stores filename as string, displays files from a directory
    /// - fileExtension: file extension to filter (e.g., "cube")
    /// - directoryProvider: closure that returns the directory URL to scan
    case file(fileExtension: String, directoryProvider: () -> URL)

    /// Get the default value as AnyCodableValue
    public var defaultValue: AnyCodableValue {
        switch self {
        case .double(let d, _): return .double(d)
        case .float(let f, _): return .double(Double(f))
        case .int(let i, _): return .int(i)
        case .bool(let b): return .bool(b)
        case .choice(let d, _): return .string(d)
        case .color(let hex): return .string(hex)
        case .file: return .string("")  // Default to empty (will show placeholder in UI)
        }
    }

    /// Get range as (min, max) doubles (for UI sliders)
    public var rangeAsDoubles: (min: Double, max: Double)? {
        switch self {
        case .double(_, let range): return (range.lowerBound, range.upperBound)
        case .float(_, let range): return (Double(range.lowerBound), Double(range.upperBound))
        case .int(_, let range): return (Double(range.lowerBound), Double(range.upperBound))
        case .bool, .choice, .color, .file: return nil
        }
    }

    /// Step size for UI (1 for ints, nil for continuous)
    public var step: Double? {
        switch self {
        case .int: return 1
        default: return nil
        }
    }

    /// Get choice options (for dropdown UI)
    public var choiceOptions: [(key: String, label: String)]? {
        switch self {
        case .choice(_, let options): return options
        default: return nil
        }
    }

    /// Check if this is a color parameter
    public var isColor: Bool {
        if case .color = self { return true }
        return false
    }

    /// Check if this is a file picker parameter
    public var isFile: Bool {
        if case .file = self { return true }
        return false
    }

    /// Get file picker info (extension and directory)
    public var filePickerInfo: (fileExtension: String, directory: URL)? {
        if case .file(let ext, let dirProvider) = self {
            return (ext, dirProvider())
        }
        return nil
    }

    // MARK: - File List Cache (shared across all file parameters)

    /// Cache for file lists, keyed by "directory|extension"
    private static var fileListCache: [String: [(key: String, label: String)]] = [:]
    private static let fileListCacheLock = NSLock()

    /// Clear the file list cache (call when user might have added new files)
    public static func clearFileListCache() {
        fileListCacheLock.lock()
        defer { fileListCacheLock.unlock() }
        fileListCache.removeAll()
        print("🔄 ParameterSpec: Cleared file list cache")
    }

    /// Get available files for file picker (cached to avoid repeated filesystem scans)
    public var availableFiles: [(key: String, label: String)] {
        guard let info = filePickerInfo else { return [] }
        let cacheKey = "\(info.directory.path)|\(info.fileExtension)"

        // Check cache first
        Self.fileListCacheLock.lock()
        if let cached = Self.fileListCache[cacheKey] {
            Self.fileListCacheLock.unlock()
            return cached
        }
        Self.fileListCacheLock.unlock()

        // Cache miss - scan filesystem
        let fm = FileManager.default
        let dir = info.directory

        // Ensure directory exists
        if !fm.fileExists(atPath: dir.path) {
            try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        }

        // Recursively enumerate all files in directory
        guard let enumerator = fm.enumerator(
            at: dir,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }

        var results: [(key: String, label: String)] = []
        for case let fileURL as URL in enumerator {
            guard fileURL.pathExtension.lowercased() == info.fileExtension.lowercased() else {
                continue
            }
            // Use relative path from base directory as key (without extension)
            let relativePath = fileURL.path.replacingOccurrences(of: dir.path + "/", with: "")
            let key = (relativePath as NSString).deletingPathExtension
            // Label shows the relative path for clarity
            results.append((key: key, label: key))
        }

        let sorted = results.sorted { $0.label.localizedCaseInsensitiveCompare($1.label) == .orderedAscending }

        // Cache the results
        Self.fileListCacheLock.lock()
        Self.fileListCache[cacheKey] = sorted
        Self.fileListCacheLock.unlock()

        return sorted
    }

    /// Custom Equatable for choice (tuples aren't Equatable by default)
    public static func == (lhs: ParameterSpec, rhs: ParameterSpec) -> Bool {
        switch (lhs, rhs) {
        case (.double(let d1, let r1), .double(let d2, let r2)):
            return d1 == d2 && r1 == r2
        case (.float(let f1, let r1), .float(let f2, let r2)):
            return f1 == f2 && r1 == r2
        case (.int(let i1, let r1), .int(let i2, let r2)):
            return i1 == i2 && r1 == r2
        case (.bool(let b1), .bool(let b2)):
            return b1 == b2
        case (.choice(let d1, let o1), .choice(let d2, let o2)):
            return d1 == d2 && o1.map(\.key) == o2.map(\.key) && o1.map(\.label) == o2.map(\.label)
        case (.color(let c1), .color(let c2)):
            return c1 == c2
        case (.file(let e1, _), .file(let e2, _)):
            return e1 == e2  // Compare extension only, not closure
        default:
            return false
        }
    }
}

// MARK: - Dictionary Helpers

extension Dictionary where Key == String, Value == ParameterSpec {
    /// Convert specs to default values dictionary
    var defaults: [String: AnyCodableValue] {
        mapValues { $0.defaultValue }
    }
}
