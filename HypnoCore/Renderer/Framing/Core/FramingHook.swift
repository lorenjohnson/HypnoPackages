//
//  FramingHook.swift
//  HypnoCore
//
//  Hook surface for per-source framing decisions.
//

/// A hook that can supply an optional framing bias for a given request.
///
/// Important: this hook must be safe to call from the renderer/compositor (non-main-thread).
public protocol FramingHook: Sendable {
    func framingBias(for request: FramingRequest) -> FramingBias?
}

/// Default no-op hook.
public struct NoOpFramingHook: FramingHook {
    public init() {}
    public func framingBias(for request: FramingRequest) -> FramingBias? { nil }
}

