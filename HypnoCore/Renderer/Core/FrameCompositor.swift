//
//  FrameCompositor.swift
//  Hypnograph
//
//  Stateless frame compositor - receives instructions, outputs frames
//  Minimal skeleton: single layer, no blending, no effects
//

import Foundation
import AVFoundation
import CoreImage
import CoreVideo
import Metal

final class FrameCompositor: NSObject, AVVideoCompositing {

    // MARK: - Properties

    /// Use shared CIContext for GPU-efficient rendering (no duplicate Metal contexts)
    private var ciContext: CIContext { SharedRenderer.ciContext }

    // Use .userInitiated instead of .userInteractive to avoid starving audio playback
    // Audio runs at .userInteractive, so our video rendering should be slightly lower priority
    private let renderQueue = DispatchQueue(label: "com.hypnograph.framecompositor", qos: .userInitiated)

    // MARK: - Slow-Mo State

    /// Previous frame per track for interpolation (trackID -> buffer, sourceIndex)
    private var prevFrameInfo: [CMPersistentTrackID: (buffer: CVPixelBuffer, sourceIndex: Int)] = [:]

    /// Output frame counter for slow-mo cache lookup
    private var outputFrameCounter: Int = 0

    /// Cross-fade fallback interpolator
    private let crossFadeInterpolator = CrossFadeInterpolator()

    // MARK: - Initialization

    override init() {
        super.init()
        // Compositor initialized - logging removed for live
    }

    // MARK: - AVVideoCompositing Protocol

    public var sourcePixelBufferAttributes: [String : any Sendable]? {
        return [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            // Ensure the upstream buffers are IOSurface-backed and Metal-compatible so
            // the display pipeline can create MTLTextures via CVMetalTextureCache
            // without extra copies.
            kCVPixelBufferMetalCompatibilityKey as String: true,
            kCVPixelBufferIOSurfacePropertiesKey as String: [String: Int]()
        ]
    }

    public var requiredPixelBufferAttributesForRenderContext: [String : any Sendable] {
        return [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferMetalCompatibilityKey as String: true,
            kCVPixelBufferIOSurfacePropertiesKey as String: [String: Int]()
        ]
    }

    public func renderContextChanged(_ newRenderContext: AVVideoCompositionRenderContext) {
        renderQueue.sync {
            // Reset slow-mo state on context change (seek, resize, etc.)
            prevFrameInfo.removeAll()
            outputFrameCounter = 0

            if #available(macOS 15.4, *) {
                sharedSlowMoPipeline.reset()
            }
        }
    }

    // MARK: - Frame Rendering

    public func startRequest(_ request: AVAsynchronousVideoCompositionRequest) {
        // Per-frame logging removed for live (30fps = 30 logs/sec)
        // NOTE: We capture self strongly here because AVFoundation owns the compositor
        // and can deallocate it at any time. If AVFoundation deallocates us while
        // we have pending work, that's an AVFoundation bug we can't fix with weak self.
        // Using weak self just causes the "self is nil" errors without fixing the root cause.
        renderQueue.async {
            self.renderFrame(request: request)
        }
    }
    
    public func cancelAllPendingVideoCompositionRequests() {
        // Nothing to cancel - we process synchronously
    }
    
    // MARK: - Core Rendering
    
    private func renderFrame(request: AVAsynchronousVideoCompositionRequest) {
        guard let instruction = request.videoCompositionInstruction as? RenderInstruction else {
            print("🔴 FrameCompositor: Invalid instruction type")
            request.finish(with: NSError(domain: "FrameCompositor", code: 2, userInfo: nil))
            return
        }

        guard let outputBuffer = request.renderContext.newPixelBuffer() else {
            print("🔴 FrameCompositor: Failed to create output buffer")
            request.finish(with: NSError(domain: "FrameCompositor", code: 3, userInfo: nil))
            return
        }

        let outputSize = CGSize(
            width: CVPixelBufferGetWidth(outputBuffer),
            height: CVPixelBufferGetHeight(outputBuffer)
        )

        // Use the effect manager from the instruction
        // All paths (preview, live display, export) now pass their manager through
        let manager = instruction.effectManager
        let frameIndex = manager?.nextFrameIndex() ?? 0

        // Composite all layers
        var composited: CIImage?

        for (index, trackID) in instruction.layerTrackIDs.enumerated() {
            let sourceIndex = instruction.sourceIndices[index]

            // Check flash solo - skip layers that shouldn't be rendered
            if let manager = manager, !manager.shouldRenderSource(at: sourceIndex) {
                continue
            }

            var layerImage: CIImage?

            // Check if this layer is a still image
            if index < instruction.stillImages.count, let stillImage = instruction.stillImages[index] {
                layerImage = stillImage
            } else {
                // Get frame from video track
                guard let sourceBuffer = request.sourceFrame(byTrackID: trackID) else {
                    print("⚠️ FrameCompositor: No source frame for track \(trackID) at \(request.compositionTime.seconds)s")
                    continue
                }

                // Apply slow-mo interpolation if needed
                let playRate = manager?.clipProvider?()?.playRate ?? 1.0

                if playRate < 1.0 {
                    layerImage = processSlowMo(
                        sourceBuffer: sourceBuffer,
                        trackID: trackID,
                        playRate: playRate,
                        compositionTime: request.compositionTime
                    )
                } else {
                    layerImage = CIImage(cvPixelBuffer: sourceBuffer)
                }
            }

            guard var img = layerImage else {
                continue
            }

            // Apply combined transform (metadata orientation + user transform)
            let transform = instruction.transforms[index]
            img = img.transformed(by: transform)

            // Ask optional framing hook for a per-source bias (smart framing).
            let bias: FramingBias? = instruction.framingHook?.framingBias(for: FramingRequest(
                renderID: instruction.renderID,
                layerIndex: index,
                sourceIndex: sourceIndex,
                time: request.compositionTime,
                sourceFraming: instruction.sourceFraming,
                outputSize: outputSize,
                sourceImage: img
            ))

            // Map source into output frame
            img = RendererImageUtils.applySourceFraming(
                image: img,
                to: outputSize,
                framing: instruction.sourceFraming,
                bias: bias
            )

            // Apply per-source effects from clip
            if instruction.enableEffects, let manager = manager {
                let clip = manager.clipProvider?()
                if let clip = clip, sourceIndex < clip.sources.count {
                    var sourceContext = manager.createContext(
                        frameIndex: frameIndex,
                        time: request.compositionTime,
                        outputSize: outputSize,
                        sourceIndex: sourceIndex
                    )
                    img = clip.sources[sourceIndex].effectChain.apply(to: img, context: &sourceContext)
                }
            }

            // Blend with previous layers
            if let base = composited {
                // Get blend mode from clip
                let blendMode: String
                let clip = manager?.clipProvider?()

                if let clip = clip, sourceIndex < clip.sources.count {
                    blendMode = sourceIndex == 0
                        ? BlendMode.sourceOver
                        : (clip.sources[sourceIndex].blendMode ?? BlendMode.defaultMontage)
                } else {
                    blendMode = instruction.blendModes[index]
                }

                // Get compensated opacity from manager (same for preview and export)
                let opacity = manager?.compensatedOpacity(
                    layerIndex: index,
                    totalLayers: instruction.layerTrackIDs.count,
                    blendMode: blendMode
                ) ?? 1.0

                img = RendererImageUtils.blend(layer: img, over: base, mode: blendMode, opacity: opacity)
                composited = img
            } else {
                composited = img
            }
        }

        guard var finalImage = composited else {
            print("🔴 FrameCompositor: No layers composited")
            request.finish(with: NSError(domain: "FrameCompositor", code: 5, userInfo: nil))
            return
        }

        // Apply blend normalization (same for preview and export)
        if let manager = manager {
            finalImage = manager.applyNormalization(to: finalImage)
        }

        // Apply global effects from clip (unless suspended, e.g., holding 0 key)
        if instruction.enableEffects, let manager = manager, !manager.isGlobalEffectSuspended {
            let clip = manager.clipProvider?()
            if let clip = clip {
                var context = manager.createContext(
                    frameIndex: frameIndex,
                    time: request.compositionTime,
                    outputSize: outputSize
                )
                finalImage = clip.effectChain.apply(to: finalImage, context: &context)
            }
        }

        // Store frame in buffer
        if let manager = manager {
            manager.recordFrame(finalImage, at: request.compositionTime)
        }

        // Render to output buffer
        ciContext.render(finalImage, to: outputBuffer)

        // Finish request
        request.finish(withComposedVideoFrame: outputBuffer)

        // Increment output frame counter for slow-mo
        outputFrameCounter += 1
    }

    // MARK: - Slow-Mo Processing

    /// Process a frame with slow-mo interpolation.
    /// Uses lookahead pipeline for VTFrameProcessor, falls back to CrossFade.
    private func processSlowMo(
        sourceBuffer: CVPixelBuffer,
        trackID: CMPersistentTrackID,
        playRate: Float,
        compositionTime: CMTime
    ) -> CIImage {
        // Calculate source frame index from composition time
        // At playRate 0.25, composition runs 4x longer than source
        let sourceTime = compositionTime.seconds * Double(playRate)
        let sourceFPS = 30.0  // Assume 30fps source
        let currentSourceIndex = Int(sourceTime * sourceFPS)

        // Get previous frame info for this track
        let prev = prevFrameInfo[trackID]
        let prevSourceIndex = prev?.sourceIndex ?? max(0, currentSourceIndex - 1)
        let prevBuffer = prev?.buffer ?? sourceBuffer

        // Update stored frame info
        prevFrameInfo[trackID] = (buffer: sourceBuffer, sourceIndex: currentSourceIndex)

        // Calculate blend factor for interpolation
        let sourcePosition = sourceTime * sourceFPS
        let blendFactor = Float(sourcePosition - floor(sourcePosition))

        // Try to get pre-computed frame from pipeline
        if #available(macOS 15.4, *) {
            // Submit frames for lookahead processing
            sharedSlowMoPipeline.submitSourceFrames(
                prevBuffer: prevBuffer,
                currentBuffer: sourceBuffer,
                prevSourceIndex: prevSourceIndex,
                currentSourceIndex: currentSourceIndex,
                currentOutputIndex: outputFrameCounter,
                playRate: playRate
            )

            // Always evict old frames to limit memory (don't wait for cache hit)
            sharedSlowMoPipeline.evictOldFrames(beforeIndex: outputFrameCounter - 10)

            // Check if we have a pre-computed frame ready
            if let interpolated = sharedSlowMoPipeline.getFrame(outputFrameIndex: outputFrameCounter) {
                return CIImage(cvPixelBuffer: interpolated)
            }
        }

        // Fallback to CrossFade
        let frame1 = CIImage(cvPixelBuffer: prevBuffer)
        let frame2 = CIImage(cvPixelBuffer: sourceBuffer)
        return crossFadeInterpolator.interpolate(frame1: frame1, frame2: frame2, blendFactor: blendFactor)
    }
}
