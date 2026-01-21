//
//  FramingBias.swift
//  HypnoCore
//
//  A framing bias produced by a FramingHook to influence per-source SourceFraming.fill.
//

import CoreGraphics

/// A bias that can influence how an aspect-fill crop is positioned, without changing sizing policy.
public struct FramingBias: Sendable, Equatable {

    public enum AxisPolicy: String, Sendable, Equatable {
        case verticalOnly
        case horizontalOnly
        case both
    }

    /// Normalized (0...1) point in the source image to treat as the focus anchor.
    /// Coordinate system: origin bottom-left.
    public var anchorNormalized: CGPoint

    /// Optional normalized bounds (0...1) in the source image the algorithm should try to keep visible.
    /// Coordinate system: origin bottom-left.
    public var boundsNormalized: CGRect?

    /// Desired target position for the anchor in output NDC space (-1...1), origin center.
    /// Example: `(0, 0.92)` places the anchor near the top-center of the output.
    public var targetNDC: CGPoint

    /// Which axes are allowed to move the crop.
    public var axisPolicy: AxisPolicy

    public init(
        anchorNormalized: CGPoint,
        boundsNormalized: CGRect? = nil,
        targetNDC: CGPoint = CGPoint(x: 0, y: 0),
        axisPolicy: AxisPolicy = .both
    ) {
        self.anchorNormalized = anchorNormalized
        self.boundsNormalized = boundsNormalized
        self.targetNDC = targetNDC
        self.axisPolicy = axisPolicy
    }
}

