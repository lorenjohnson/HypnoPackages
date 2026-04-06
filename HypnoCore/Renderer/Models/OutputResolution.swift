//
//  OutputResolution.swift
//  HypnoCore
//

import Foundation

/// Standard video resolutions (720p, 1080p, 4K).
/// The raw value is the constraining dimension used for rendering.
public enum OutputResolution: Int, Codable, CaseIterable, Sendable {
    case p720 = 720
    case p1080 = 1080
    case p4K = 2160

    public var displayName: String {
        switch self {
        case .p720: return "720p"
        case .p1080: return "1080p"
        case .p4K: return "4K"
        }
    }

    public var maxDimension: Int { rawValue }
}
