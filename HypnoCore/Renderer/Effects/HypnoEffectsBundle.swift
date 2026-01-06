//
//  HypnoEffectsBundle.swift
//  HypnoEffects
//
//  Central bundle lookup for HypnoEffects resources.
//

import Foundation

enum HypnoEffectsBundle {
    static let bundle = Bundle(for: BundleAnchor.self)

    private final class BundleAnchor {}
}
