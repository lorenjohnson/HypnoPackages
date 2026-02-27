//
//  MetalPassChainContract.swift
//  Hypnograph
//
//  Runtime contract for all-Metal pass-chain effects.
//  Defines how passes declare parameter schemas, texture inputs, and outputs.
//

import Foundation

/// Parameter schema for a pass or chain.
/// Keeps ordering stable for UI while preserving typed specs for validation/defaults.
public struct MetalPassParameterSchema: Equatable {
    public var specs: [String: ParameterSpec]
    public var order: [String]

    public init(specs: [String: ParameterSpec], order: [String]? = nil) {
        self.specs = specs
        if let explicitOrder = order, !explicitOrder.isEmpty {
            var resolved = explicitOrder.filter { specs[$0] != nil }
            resolved.append(contentsOf: specs.keys.sorted().filter { !resolved.contains($0) })
            self.order = resolved
        } else {
            self.order = specs.keys.sorted()
        }
    }

    public var defaultValues: [String: AnyCodableValue] {
        specs.defaults
    }
}

/// High-level source for a texture argument in a pass.
public enum MetalPassTextureSourceKind: String {
    case currentFrame
    case previousPass
    case history
    case persistentSurface
}

/// Declares where a pass texture input should come from.
public struct MetalPassTextureSource: Equatable {
    public var kind: MetalPassTextureSourceKind
    public var historyOffset: Int?
    public var persistentSurfaceID: String?

    public init(
        kind: MetalPassTextureSourceKind,
        historyOffset: Int? = nil,
        persistentSurfaceID: String? = nil
    ) {
        self.kind = kind
        self.historyOffset = historyOffset
        self.persistentSurfaceID = persistentSurfaceID
    }

    public static var currentFrame: MetalPassTextureSource {
        MetalPassTextureSource(kind: .currentFrame)
    }

    public static var previousPass: MetalPassTextureSource {
        MetalPassTextureSource(kind: .previousPass)
    }

    public static func history(offset: Int) -> MetalPassTextureSource {
        MetalPassTextureSource(kind: .history, historyOffset: offset)
    }

    public static func persistentSurface(id: String) -> MetalPassTextureSource {
        MetalPassTextureSource(kind: .persistentSurface, persistentSurfaceID: id)
    }
}

/// Binds one texture argument index in a kernel to a source.
public struct MetalPassTextureInputBinding: Equatable {
    public var argumentIndex: Int
    public var source: MetalPassTextureSource

    public init(argumentIndex: Int, source: MetalPassTextureSource) {
        self.argumentIndex = argumentIndex
        self.source = source
    }
}

/// Output destination for a pass texture write.
public enum MetalPassTextureOutputKind: String {
    case nextPass
    case finalImage
    case persistentSurface
}

/// Declares where a pass output texture should be written.
public struct MetalPassTextureOutputTarget: Equatable {
    public var kind: MetalPassTextureOutputKind
    public var persistentSurfaceID: String?

    public init(kind: MetalPassTextureOutputKind, persistentSurfaceID: String? = nil) {
        self.kind = kind
        self.persistentSurfaceID = persistentSurfaceID
    }

    public static var nextPass: MetalPassTextureOutputTarget {
        MetalPassTextureOutputTarget(kind: .nextPass)
    }

    public static var finalImage: MetalPassTextureOutputTarget {
        MetalPassTextureOutputTarget(kind: .finalImage)
    }

    public static func persistentSurface(id: String) -> MetalPassTextureOutputTarget {
        MetalPassTextureOutputTarget(kind: .persistentSurface, persistentSurfaceID: id)
    }
}

/// Binds one writeable texture argument index to an output target.
public struct MetalPassTextureOutputBinding: Equatable {
    public var argumentIndex: Int
    public var target: MetalPassTextureOutputTarget

    public init(argumentIndex: Int, target: MetalPassTextureOutputTarget) {
        self.argumentIndex = argumentIndex
        self.target = target
    }
}

/// Persistent GPU surface reserved for an effect instance.
/// Used for feedback loops and multi-frame mutated state.
public struct MetalPassPersistentSurfaceSpec: Equatable {
    public var id: String
    public var pixelFormat: String

    public init(id: String, pixelFormat: String = "bgra8Unorm") {
        self.id = id
        self.pixelFormat = pixelFormat
    }
}

/// One Metal kernel pass inside an effect.
public struct MetalPassDefinition: Equatable {
    public var id: String
    public var displayName: String?
    public var functionName: String
    /// Buffer index expected by the kernel for scalar params.
    public var parameterBufferIndex: Int
    public var parameterSchema: MetalPassParameterSchema
    public var textureInputs: [MetalPassTextureInputBinding]
    public var textureOutputs: [MetalPassTextureOutputBinding]

    public init(
        id: String,
        displayName: String? = nil,
        functionName: String,
        parameterBufferIndex: Int = 0,
        parameterSchema: MetalPassParameterSchema = MetalPassParameterSchema(specs: [:]),
        textureInputs: [MetalPassTextureInputBinding],
        textureOutputs: [MetalPassTextureOutputBinding]
    ) {
        self.id = id
        self.displayName = displayName
        self.functionName = functionName
        self.parameterBufferIndex = parameterBufferIndex
        self.parameterSchema = parameterSchema
        self.textureInputs = textureInputs
        self.textureOutputs = textureOutputs
    }
}

/// Full definition for a custom effect composed of multiple Metal passes.
/// This is the contract we can eventually serialize and expose in Shader Studio.
public struct MetalPassChainDefinition: Equatable {
    public var id: String
    public var name: String
    public var chainParameters: MetalPassParameterSchema
    public var passes: [MetalPassDefinition]
    public var persistentSurfaces: [MetalPassPersistentSurfaceSpec]

    public init(
        id: String,
        name: String,
        chainParameters: MetalPassParameterSchema = MetalPassParameterSchema(specs: [:]),
        passes: [MetalPassDefinition],
        persistentSurfaces: [MetalPassPersistentSurfaceSpec] = []
    ) {
        self.id = id
        self.name = name
        self.chainParameters = chainParameters
        self.passes = passes
        self.persistentSurfaces = persistentSurfaces
    }

    /// Max frame-history offset needed by any pass.
    /// Can be used as requiredLookback for Effect wiring.
    public var requiredLookback: Int {
        passes
            .flatMap(\.textureInputs)
            .compactMap { binding in
                guard binding.source.kind == .history else { return nil }
                return binding.source.historyOffset
            }
            .max() ?? 0
    }

    public var usesPersistentState: Bool {
        let surfacesInInputs = passes
            .flatMap(\.textureInputs)
            .contains { $0.source.kind == .persistentSurface }
        let surfacesInOutputs = passes
            .flatMap(\.textureOutputs)
            .contains { $0.target.kind == .persistentSurface }
        return surfacesInInputs || surfacesInOutputs || !persistentSurfaces.isEmpty
    }

    /// Structural validation warnings for authoring tools.
    public func validationWarnings() -> [String] {
        var warnings: [String] = []
        let declaredSurfaceIDs = Set(persistentSurfaces.map(\.id))

        for pass in passes {
            if pass.textureOutputs.isEmpty {
                warnings.append("Pass '\(pass.id)' has no output binding.")
            }

            for binding in pass.textureInputs {
                let src = binding.source
                if src.kind == .history {
                    guard let offset = src.historyOffset, offset >= 1 else {
                        warnings.append("Pass '\(pass.id)' has invalid history offset at texture index \(binding.argumentIndex).")
                        continue
                    }
                }
                if src.kind == .persistentSurface {
                    guard let id = src.persistentSurfaceID, !id.isEmpty else {
                        warnings.append("Pass '\(pass.id)' uses persistent surface without an id at texture index \(binding.argumentIndex).")
                        continue
                    }
                    if !declaredSurfaceIDs.contains(id) {
                        warnings.append("Pass '\(pass.id)' references undeclared persistent surface '\(id)'.")
                    }
                }
            }

            for output in pass.textureOutputs {
                let target = output.target
                if target.kind == .persistentSurface {
                    guard let id = target.persistentSurfaceID, !id.isEmpty else {
                        warnings.append("Pass '\(pass.id)' writes to persistent surface without an id at texture index \(output.argumentIndex).")
                        continue
                    }
                    if !declaredSurfaceIDs.contains(id) {
                        warnings.append("Pass '\(pass.id)' writes to undeclared persistent surface '\(id)'.")
                    }
                }
            }
        }

        return warnings
    }
}

