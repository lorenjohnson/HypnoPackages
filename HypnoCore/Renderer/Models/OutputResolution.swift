//
//  OutputResolution.swift
//  HypnoCore
//

import Foundation

/// Standard video resolutions (72p, 144p, 240p, 480p, 720p, 1080p, 4K).
/// The raw value is the constraining dimension used for rendering.
public enum OutputResolution: Int, Codable, CaseIterable, Sendable {
    case p72 = 72
    case p144 = 144
    case p240 = 240
    case p480 = 480
    case p720 = 720
    case p1080 = 1080
    case p4K = 2160

    public var displayName: String {
        switch self {
        case .p72: return "72p"
        case .p144: return "144p"
        case .p240: return "240p"
        case .p480: return "480p"
        case .p720: return "720p"
        case .p1080: return "1080p"
        case .p4K: return "4K"
        }
    }

    public var maxDimension: Int { rawValue }
}
