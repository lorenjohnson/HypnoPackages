//
//  FramingPipelineHook.swift
//  HypnoCore
//
//  Allows composition of multiple FramingHook implementations.
//

/// A simple composite hook that tries hooks in order and returns the first non-nil bias.
public struct FramingPipelineHook: FramingHook {
    public var hooks: [any FramingHook]

    public init(hooks: [any FramingHook]) {
        self.hooks = hooks
    }

    public func framingBias(for request: FramingRequest) -> FramingBias? {
        for hook in hooks {
            if let bias = hook.framingBias(for: request) { return bias }
        }
        return nil
    }
}

