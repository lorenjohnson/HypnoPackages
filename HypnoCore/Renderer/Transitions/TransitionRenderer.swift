//
//  TransitionRenderer.swift
//  HypnoCore
//
//  Metal-based transition renderer for shader transitions between textures.
//  Replaces view-level alpha fades with per-pixel GPU transitions.
//

import Metal
import simd

/// Renders shader-based transitions between two textures.
public final class TransitionRenderer {

    // MARK: - Types

    /// Available transition types
    public enum TransitionType: String, CaseIterable, Codable {
        case crossfade      // Linear alpha blend
        case punk           // Stepped/jittery blend with noise
        case wipeLeft       // Wipe from right to left
        case wipeRight      // Wipe from left to right
        case wipeUp         // Wipe from bottom to top
        case wipeDown       // Wipe from top to bottom
        case dissolve       // Noise-based dissolve

        /// Shader function name for this transition
        var shaderName: String {
            switch self {
            case .crossfade: return "transitionCrossfade"
            case .punk: return "transitionPunk"
            case .wipeLeft: return "transitionWipeLeft"
            case .wipeRight: return "transitionWipeRight"
            case .wipeUp: return "transitionWipeUp"
            case .wipeDown: return "transitionWipeDown"
            case .dissolve: return "transitionDissolve"
            }
        }
    }

    /// Parameters passed to transition shaders
    struct TransitionParams {
        var progress: Float      // 0.0 to 1.0
        var width: Int32
        var height: Int32
        var seed: UInt32         // Random seed for noise-based transitions
        var softness: Float      // Edge softness for wipes (0.0 to 0.5)
        var _padding: Float = 0  // Alignment padding
    }

    // MARK: - Properties

    private let device: MTLDevice
    private let commandQueue: MTLCommandQueue
    private var pipelineStates: [TransitionType: MTLComputePipelineState] = [:]

    /// Whether the renderer is properly initialized
    public var isValid: Bool {
        !pipelineStates.isEmpty
    }

    // MARK: - Initialization

    public init(device: MTLDevice = SharedRenderer.device) {
        self.device = device
        self.commandQueue = device.makeCommandQueue()!

        loadShaders()
    }

    private func loadShaders() {
        guard let library = try? device.makeDefaultLibrary(bundle: Bundle(for: TransitionRenderer.self)) else {
            print("TransitionRenderer: Failed to load shader library")
            return
        }

        for type in TransitionType.allCases {
            guard let function = library.makeFunction(name: type.shaderName) else {
                print("TransitionRenderer: Shader '\(type.shaderName)' not found")
                continue
            }

            do {
                let pipeline = try device.makeComputePipelineState(function: function)
                pipelineStates[type] = pipeline
            } catch {
                print("TransitionRenderer: Failed to create pipeline for \(type): \(error)")
            }
        }
    }

    // MARK: - Rendering

    /// Render a transition between two textures
    /// - Parameters:
    ///   - outgoing: The texture being transitioned from
    ///   - incoming: The texture being transitioned to
    ///   - output: The output texture to write to
    ///   - type: The type of transition to apply
    ///   - progress: Transition progress (0.0 = fully outgoing, 1.0 = fully incoming)
    ///   - softness: Edge softness for wipe transitions (0.0 to 0.5)
    ///   - commandBuffer: The command buffer to encode into
    public func render(
        outgoing: MTLTexture,
        incoming: MTLTexture,
        output: MTLTexture,
        type: TransitionType,
        progress: Float,
        softness: Float = 0.02,
        commandBuffer: MTLCommandBuffer
    ) {
        guard let pipeline = pipelineStates[type] else {
            print("TransitionRenderer: No pipeline for \(type)")
            return
        }

        guard let encoder = commandBuffer.makeComputeCommandEncoder() else {
            return
        }

        encoder.setComputePipelineState(pipeline)

        // Set textures
        encoder.setTexture(outgoing, index: 0)
        encoder.setTexture(incoming, index: 1)
        encoder.setTexture(output, index: 2)

        // Set parameters
        var params = TransitionParams(
            progress: progress,
            width: Int32(output.width),
            height: Int32(output.height),
            seed: UInt32.random(in: 0...UInt32.max),
            softness: softness
        )
        encoder.setBytes(&params, length: MemoryLayout<TransitionParams>.size, index: 0)

        // Calculate threadgroup size
        let threadgroupSize = MTLSize(width: 16, height: 16, depth: 1)
        let threadgroups = MTLSize(
            width: (output.width + 15) / 16,
            height: (output.height + 15) / 16,
            depth: 1
        )

        encoder.dispatchThreadgroups(threadgroups, threadsPerThreadgroup: threadgroupSize)
        encoder.endEncoding()
    }

    /// Render a transition and wait for completion
    /// - Returns: true if rendering succeeded
    @discardableResult
    public func renderSync(
        outgoing: MTLTexture,
        incoming: MTLTexture,
        output: MTLTexture,
        type: TransitionType,
        progress: Float,
        softness: Float = 0.02
    ) -> Bool {
        guard let commandBuffer = commandQueue.makeCommandBuffer() else {
            return false
        }

        render(
            outgoing: outgoing,
            incoming: incoming,
            output: output,
            type: type,
            progress: progress,
            softness: softness,
            commandBuffer: commandBuffer
        )

        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()

        return commandBuffer.status == .completed
    }
}
