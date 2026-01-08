//
//  CoreGraphics.swift
//  HypnoCore
//
//  Extensions for CoreGraphics types.

import CoreGraphics

// MARK: - CGSize

public extension CGSize {
    static func + (lhs: CGSize, rhs: CGSize) -> CGSize {
        CGSize(width: lhs.width + rhs.width, height: lhs.height + rhs.height)
    }
}
