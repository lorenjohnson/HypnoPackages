//
//  Foundation.swift
//  HypnoCore
//
//  Extensions for Foundation types.

import Foundation

// MARK: - Int

public extension Int {
    /// Returns the positive modulo of self by n.
    /// Unlike the % operator, this always returns a non-negative result.
    func positiveMod(_ n: Int) -> Int {
        let r = self % n
        return r >= 0 ? r : r + n
    }
}

// MARK: - Comparable

public extension Comparable {
    /// Clamps the value to the given closed range.
    func clamped(to range: ClosedRange<Self>) -> Self {
        min(max(self, range.lowerBound), range.upperBound)
    }
}
