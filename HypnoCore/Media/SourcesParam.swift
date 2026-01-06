//
//  SourcesParam.swift
//  HypnoCore
//
//  Polymorphic Codable type for settings source definitions.
//  Supports both simple array format and named dictionary format.
//

import Foundation

/// Polymorphic type for source folder definitions in settings.
///
/// Supports three JSON formats:
/// - Array: `["~/Movies/sources"]` → single "default" library
/// - Dictionary with arrays: `{"Archive": ["~/path1", "~/path2"]}` → named libraries
/// - Dictionary with strings: `{"Archive": "~/path"}` → convenience for single paths
public enum SourcesParam: Codable, Sendable {
    case array([String])
    case dictionary([String: [String]])

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()

        // Try [String: [String]] first (most explicit)
        if let dictArray = try? container.decode([String: [String]].self) {
            self = .dictionary(dictArray)
            return
        }

        // Try [String: String] (convenience format)
        if let dictString = try? container.decode([String: String].self) {
            self = .dictionary(dictString.mapValues { [$0] })
            return
        }

        // Try [String] (simple array)
        if let array = try? container.decode([String].self) {
            self = .array(array)
            return
        }

        throw DecodingError.typeMismatch(
            SourcesParam.self,
            .init(codingPath: decoder.codingPath,
                  debugDescription: "Expected [String], [String: String], or [String: [String]]")
        )
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .array(let array):
            try container.encode(array)
        case .dictionary(let dict):
            try container.encode(dict)
        }
    }

    /// Named libraries with their folder paths (tilde not expanded)
    public var libraries: [String: [String]] {
        switch self {
        case .array(let array):
            return ["default": array]
        case .dictionary(let dict):
            return dict
        }
    }

    /// Order of library keys for consistent menu display
    public var libraryOrder: [String] {
        switch self {
        case .array:
            return ["default"]
        case .dictionary(let dict):
            return Array(dict.keys)
        }
    }

    /// Default library key to use when none specified
    public var defaultKey: String {
        let libs = libraries
        if libs.keys.contains("default") { return "default" }
        if let key = libs.keys.first(where: { $0.lowercased() == "default" }) { return key }
        return libraryOrder.first ?? "default"
    }
}
