//
//  SourceFraming.swift
//  HypnoCore
//
//  Global framing mode for mapping a source into the output frame.
//

import Foundation

public enum SourceFraming: String, Codable, CaseIterable, Sendable {
    case fill
    case fit

    public var displayName: String {
        switch self {
        case .fill: "Fill"
        case .fit: "Fit"
        }
    }
}

