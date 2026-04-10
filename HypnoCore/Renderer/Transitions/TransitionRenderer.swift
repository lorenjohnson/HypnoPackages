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
            case none
            case crossfade
            case fadeToBlack
            case blur
            case slideUp
            case slideLeft

            /// Display name for UI
            public var displayName: String {
                switch self {
                case .none: return "None"
                case .crossfade: return "Crossfade"
                case .fadeToBlack: return "Fade to Black"
                case .blur: return "Blur"
                case .slideUp: return "Slide Up"
                case .slideLeft: return "Slide Left"
                }
            }

            /// Shader function name for this transition (nil for instant cut)
            var shaderName: String? {
                switch self {
                case .none: return nil
                case .crossfade: return "transitionCrossfade"
                case .fadeToBlack: return "transitionFadeToBlack"
                case .blur: return "transitionBlur"
                case .slideUp: return "transitionSlideUp"
                case .slideLeft: return "transitionSlideLeft"
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
    private let commandQueue: MTLCommandQueue?
    private var pipelineStates: [TransitionType: MTLComputePipelineState] = [:]

    /// Whether the renderer is properly initialized
    public var isValid: Bool {
        commandQueue != nil && !pipelineStates.isEmpty
    }

    // MARK: - Initialization

    public init(device: MTLDevice = SharedRenderer.device) {
        self.device = device
        self.commandQueue = device.makeCommandQueue()

        if commandQueue == nil {
            print("TransitionRenderer: Failed to create command queue")
        }

        loadShaders()
    }

    private func loadShaders() {
        guard let library = try? device.makeDefaultLibrary(bundle: HypnoCoreBundle.bundle) else {
            print("TransitionRenderer: Failed to load shader library")
            return
        }

        for type in TransitionType.allCases {
            // Skip types without shaders (e.g., .none)
            guard let shaderName = type.shaderName else { continue }

            guard let function = library.makeFunction(name: shaderName) else {
                print("TransitionRenderer: Shader '\(shaderName)' not found in library")
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
    ///   - seed: Random seed for noise-based transitions (should stay constant per transition)
    ///   - softness: Edge softness for wipe transitions (0.0 to 0.5)
    ///   - commandBuffer: The command buffer to encode into
    public func render(
        outgoing: MTLTexture,
        incoming: MTLTexture,
        output: MTLTexture,
        type: TransitionType,
        progress: Float,
        seed: UInt32 = 0,
        softness: Float = 0.02,
        commandBuffer: MTLCommandBuffer
    ) {
        guard let pipeline = pipelineStates[type] else {
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
            seed: seed,
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
        seed: UInt32 = 0,
        softness: Float = 0.02
    ) -> Bool {
        guard let commandBuffer = commandQueue?.makeCommandBuffer() else {
            return false
        }

        render(
            outgoing: outgoing,
            incoming: incoming,
            output: output,
            type: type,
            progress: progress,
            seed: seed,
            softness: softness,
            commandBuffer: commandBuffer
        )

        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()

        return commandBuffer.status == .completed
    }
}
