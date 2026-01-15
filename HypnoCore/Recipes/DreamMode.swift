//
//  DreamMode.swift
//  HypnoEffects
//
//  Legacy field retained for decoding older recipes.
//  Hypnograph no longer supports a separate "sequence" mode.
//

import Foundation

public enum DreamMode: String, Codable {
    case montage

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let rawValue = (try? container.decode(String.self)) ?? DreamMode.montage.rawValue
        self = DreamMode(rawValue: rawValue) ?? .montage
    }
}
