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
    // MARK: - Cancellation

    /// AVFoundation can request cancellation when seeking, scrubbing, or if it needs to drop work.
    /// If we don't honor this, the render queue can build a backlog of stale requests, causing
    /// video to "freeze" while audio continues until the backlog drains.
    private let cancellationLock = NSLock()
    private var cancellationToken: UInt64 = 0

    private func currentCancellationToken() -> UInt64 {
        cancellationLock.lock()
        defer { cancellationLock.unlock() }
        return cancellationToken
    }

    private func bumpCancellationToken() {
        cancellationLock.lock()
        cancellationToken &+= 1
        cancellationLock.unlock()
    }

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
        let token = currentCancellationToken()
        renderQueue.async {
            autoreleasepool {
                self.renderFrame(request: request, cancellationToken: token)
            }
        }
    }
    
    public func cancelAllPendingVideoCompositionRequests() {
        // Bump the token so queued render work will early-out.
        bumpCancellationToken()
    }
    
    // MARK: - Core Rendering
    
    private func renderFrame(request: AVAsynchronousVideoCompositionRequest, cancellationToken token: UInt64) {
        // Drop work if AVFoundation has requested cancellation since this request was queued.
        guard token == currentCancellationToken() else {
            request.finishCancelledRequest()
            return
        }

        guard token == currentCancellationToken() else {
            request.finishCancelledRequest()
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

        let finalImage: CIImage
        if let instruction = request.videoCompositionInstruction as? SequenceRenderInstruction {
            guard let image = renderSequenceInstruction(
                instruction,
                request: request,
                outputSize: outputSize,
                cancellationToken: token
            ) else {
                request.finish(with: frameRenderError(
                    code: 5,
                    description: "Failed to render sequence instruction at \(request.compositionTime.seconds)s"
                ))
                return
            }
            finalImage = image
        } else if let instruction = request.videoCompositionInstruction as? RenderInstruction {
            let pass = CompositionRenderPass(
                timeRange: instruction.timeRange,
                compositionTimeStart: .zero,
                layerTrackIDs: instruction.layerTrackIDs,
                blendModes: instruction.blendModes,
                transforms: instruction.transforms,
                sourceIndices: instruction.sourceIndices,
                enableEffects: instruction.enableEffects,
                stillImages: instruction.stillImages,
                sourceFraming: instruction.sourceFraming,
                framingHook: instruction.framingHook,
                renderID: instruction.renderID,
                effectManager: instruction.effectManager,
                applyHypnogramEffectsFromManager: true
            )

            guard let result = renderCompositionPass(
                pass,
                request: request,
                outputSize: outputSize,
                sequenceTime: request.compositionTime,
                cancellationToken: token
            ) else {
                request.finish(with: frameRenderError(
                    code: 5,
                    description: "Failed to render composition instruction at \(request.compositionTime.seconds)s"
                ))
                return
            }
            finalImage = result
        } else {
            print("🔴 FrameCompositor: Invalid instruction type")
            request.finish(with: frameRenderError(
                code: 2,
                description: "Invalid instruction type \(type(of: request.videoCompositionInstruction))"
            ))
            return
        }

        guard token == currentCancellationToken() else {
            request.finishCancelledRequest()
            return
        }

        guard token == currentCancellationToken() else {
            request.finishCancelledRequest()
            return
        }

        // Render to output buffer
        ciContext.render(finalImage, to: outputBuffer)

        // Finish request
        request.finish(withComposedVideoFrame: outputBuffer)

        // Increment output frame counter for slow-mo
        outputFrameCounter += 1
    }

    private func renderSequenceInstruction(
        _ instruction: SequenceRenderInstruction,
        request: AVAsynchronousVideoCompositionRequest,
        outputSize: CGSize,
        cancellationToken token: UInt64
    ) -> CIImage? {
        guard let sample = instruction.plan.sample(at: request.compositionTime) else {
            print("🔴 FrameCompositor: Sequence plan had no sample at \(request.compositionTime.seconds)s")
            return nil
        }

        switch sample {
        case .composition(let sample):
            guard let pass = instruction.passesByIndex[sample.compositionIndex] else {
                print("🔴 FrameCompositor: Missing pass for composition \(sample.compositionIndex)")
                return nil
            }

            guard var image = renderCompositionPass(
                pass,
                request: request,
                outputSize: outputSize,
                sequenceTime: request.compositionTime,
                cancellationToken: token,
                localTimeOverride: sample.compositionTime
            ) else {
                return nil
            }

            image = applySequenceEffects(
                to: image,
                using: instruction.sequenceEffectManager,
                sequenceTime: request.compositionTime,
                outputSize: outputSize
            )
            return image

        case .transition(let sample):
            guard let outgoing = instruction.passesByIndex[sample.outgoingCompositionIndex],
                  let incoming = instruction.passesByIndex[sample.incomingCompositionIndex] else {
                print(
                    "🔴 FrameCompositor: Missing transition pass outgoing=\(sample.outgoingCompositionIndex) incoming=\(sample.incomingCompositionIndex)"
                )
                return nil
            }

            let outgoingImage = renderCompositionPass(
                outgoing,
                request: request,
                outputSize: outputSize,
                sequenceTime: request.compositionTime,
                cancellationToken: token,
                localTimeOverride: sample.outgoingCompositionTime
            )
            let incomingImage = renderCompositionPass(
                incoming,
                request: request,
                outputSize: outputSize,
                sequenceTime: request.compositionTime,
                cancellationToken: token,
                localTimeOverride: sample.incomingCompositionTime
            )

            guard token == currentCancellationToken() else { return nil }

            let extent = CGRect(origin: .zero, size: outputSize)
            var image = applyTransition(
                outgoing: outgoingImage,
                incoming: incomingImage,
                style: sample.style,
                progress: CGFloat(sample.progress),
                extent: extent
            )

            image = applySequenceEffects(
                to: image,
                using: instruction.sequenceEffectManager,
                sequenceTime: request.compositionTime,
                outputSize: outputSize
            )
            return image
        }
    }

    private func renderCompositionPass(
        _ pass: CompositionRenderPass,
        request: AVAsynchronousVideoCompositionRequest,
        outputSize: CGSize,
        sequenceTime: CMTime,
        cancellationToken token: UInt64,
        localTimeOverride: CMTime? = nil
    ) -> CIImage? {
        guard token == currentCancellationToken() else { return nil }

        let manager = pass.effectManager
        let localTime = localTimeOverride ?? pass.localTime(for: sequenceTime)
        let frameIndex = manager?.nextFrameIndex() ?? 0
        let composition = manager?.compositionProvider?()

        var composited: CIImage?

        for (index, trackID) in pass.layerTrackIDs.enumerated() {
            guard token == currentCancellationToken() else { return nil }

            let sourceIndex = pass.sourceIndices[index]
            if let manager, !manager.shouldRenderSource(at: sourceIndex) {
                continue
            }

            var layerImage: CIImage?
            if index < pass.stillImages.count, let stillImage = pass.stillImages[index] {
                layerImage = stillImage
            } else if let sourceBuffer = request.sourceFrame(byTrackID: trackID) {
                let playRate = manager?.compositionProvider?()?.playRate ?? 1.0
                if playRate < 1.0 {
                    layerImage = processSlowMo(
                        sourceBuffer: sourceBuffer,
                        trackID: trackID,
                        playRate: playRate,
                        compositionTime: localTime
                    )
                } else {
                    layerImage = CIImage(cvPixelBuffer: sourceBuffer)
                }
            } else {
                print(
                    "⚠️ FrameCompositor: Missing source frame " +
                    "track=\(trackID) sequenceTime=\(sequenceTime.seconds) localTime=\(localTime.seconds) " +
                    "passStart=\(pass.timeRange.start.seconds) passDuration=\(pass.timeRange.duration.seconds) " +
                    "sourceIndex=\(sourceIndex)"
                )
                continue
            }

            guard var img = layerImage else { continue }

            img = img.transformed(by: pass.transforms[index])

            let bias = pass.framingHook?.framingBias(for: FramingRequest(
                renderID: pass.renderID,
                layerIndex: index,
                sourceIndex: sourceIndex,
                time: localTime,
                sourceFraming: pass.sourceFraming,
                outputSize: outputSize,
                sourceImage: img
            ))

            img = RendererImageUtils.applySourceFraming(
                image: img,
                to: outputSize,
                framing: pass.sourceFraming,
                bias: bias
            )

            if pass.enableEffects, let manager, let composition, sourceIndex < composition.layers.count {
                var sourceContext = manager.createContext(
                    frameIndex: frameIndex,
                    time: localTime,
                    outputSize: outputSize,
                    sourceIndex: sourceIndex
                )
                img = composition.layers[sourceIndex].effectChain.apply(to: img, context: &sourceContext)
            }

            if let base = composited {
                let blendMode: String
                if let composition, sourceIndex < composition.layers.count {
                    blendMode = sourceIndex == 0
                        ? BlendMode.sourceOver
                        : (composition.layers[sourceIndex].blendMode ?? BlendMode.defaultMontage)
                } else {
                    blendMode = pass.blendModes[index]
                }

                let compensatedOpacity = manager?.compensatedOpacity(
                    layerIndex: index,
                    totalLayers: pass.layerTrackIDs.count,
                    blendMode: blendMode
                ) ?? 1.0

                let userOpacity: Double
                if let composition, sourceIndex >= 0, sourceIndex < composition.layers.count {
                    userOpacity = composition.layers[sourceIndex].opacity
                } else {
                    userOpacity = 1.0
                }

                let opacity = compensatedOpacity * CGFloat(max(0.0, min(userOpacity, 1.0)))
                img = RendererImageUtils.blend(layer: img, over: base, mode: blendMode, opacity: opacity)
                composited = img
            } else {
                let userOpacity: Double
                if let composition, sourceIndex >= 0, sourceIndex < composition.layers.count {
                    userOpacity = composition.layers[sourceIndex].opacity
                } else {
                    userOpacity = 1.0
                }
                let opacity = CGFloat(max(0.0, min(userOpacity, 1.0)))
                if opacity < 1.0 {
                    let background = CIImage(color: .black).cropped(to: CGRect(origin: .zero, size: outputSize))
                    composited = RendererImageUtils.blend(layer: img, over: background, mode: BlendMode.sourceOver, opacity: opacity)
                } else {
                    composited = img
                }
            }
        }

        guard var finalImage = composited else {
            print(
                "🔴 FrameCompositor: No layers composited " +
                "sequenceTime=\(sequenceTime.seconds) passStart=\(pass.timeRange.start.seconds) " +
                "passDuration=\(pass.timeRange.duration.seconds) layerTrackCount=\(pass.layerTrackIDs.count)"
            )
            return nil
        }

        if let manager {
            finalImage = manager.applyNormalization(to: finalImage)
        }

        if pass.enableEffects, let manager, !manager.isCompositionEffectSuspended, let composition {
            var context = manager.createContext(
                frameIndex: frameIndex,
                time: localTime,
                outputSize: outputSize
            )
            finalImage = composition.effectChain.apply(to: finalImage, context: &context)
        }

        if pass.enableEffects, pass.applyHypnogramEffectsFromManager, let manager {
            let hypnogramChain = manager.hypnogramEffectChain
            if !hypnogramChain.effects.isEmpty {
                var context = manager.createContext(
                    frameIndex: frameIndex,
                    time: localTime,
                    outputSize: outputSize
                )
                finalImage = hypnogramChain.apply(to: finalImage, context: &context)
            }
        }

        manager?.recordFrame(finalImage, at: localTime)
        return finalImage
    }

    private func applySequenceEffects(
        to image: CIImage,
        using manager: EffectManager?,
        sequenceTime: CMTime,
        outputSize: CGSize
    ) -> CIImage {
        guard let manager else { return image }
        let hypnogramChain = manager.hypnogramEffectChain
        guard !hypnogramChain.effects.isEmpty else { return image }

        let frameIndex = manager.nextFrameIndex()
        var context = manager.createContext(
            frameIndex: frameIndex,
            time: sequenceTime,
            outputSize: outputSize
        )
        let finalImage = hypnogramChain.apply(to: image, context: &context)
        manager.recordFrame(finalImage, at: sequenceTime)
        return finalImage
    }

    private func applyTransition(
        outgoing: CIImage?,
        incoming: CIImage?,
        style: TransitionRenderer.TransitionType,
        progress: CGFloat,
        extent: CGRect
    ) -> CIImage {
        let black = CIImage(color: .black).cropped(to: extent)
        let clamped = max(0, min(progress, 1))

        switch style {
        case .none:
            return clamped < 1 ? (outgoing ?? black) : (incoming ?? black)

        case .crossfade:
            return blendTransition(
                outgoing: outgoing ?? black,
                incoming: incoming ?? black,
                progress: clamped,
                extent: extent
            )

        case .fadeToBlack:
            if clamped < 0.5 {
                return blendTransition(
                    outgoing: outgoing ?? black,
                    incoming: black,
                    progress: clamped * 2,
                    extent: extent
                )
            } else {
                return blendTransition(
                    outgoing: black,
                    incoming: incoming ?? black,
                    progress: (clamped - 0.5) * 2,
                    extent: extent
                )
            }

        case .blur:
            let blurRadius = 12 * clamped
            let blurredOutgoing = (outgoing ?? black)
                .clampedToExtent()
                .applyingFilter("CIGaussianBlur", parameters: ["inputRadius": blurRadius])
                .cropped(to: extent)
            let blurredIncoming = (incoming ?? black)
                .clampedToExtent()
                .applyingFilter("CIGaussianBlur", parameters: ["inputRadius": 12 * (1 - clamped)])
                .cropped(to: extent)
            return blendTransition(
                outgoing: blurredOutgoing,
                incoming: blurredIncoming,
                progress: clamped,
                extent: extent
            )

        case .slideLeft:
            let width = extent.width
            let outgoingTranslated = (outgoing ?? black)
                .transformed(by: CGAffineTransform(translationX: -width * clamped, y: 0))
            let incomingTranslated = (incoming ?? black)
                .transformed(by: CGAffineTransform(translationX: width * (1 - clamped), y: 0))
            return incomingTranslated.composited(over: outgoingTranslated.composited(over: black)).cropped(to: extent)

        case .slideUp:
            let height = extent.height
            let outgoingTranslated = (outgoing ?? black)
                .transformed(by: CGAffineTransform(translationX: 0, y: height * clamped))
            let incomingTranslated = (incoming ?? black)
                .transformed(by: CGAffineTransform(translationX: 0, y: -height * (1 - clamped)))
            return incomingTranslated.composited(over: outgoingTranslated.composited(over: black)).cropped(to: extent)
        }
    }

    private func blendTransition(
        outgoing: CIImage,
        incoming: CIImage,
        progress: CGFloat,
        extent: CGRect
    ) -> CIImage {
        let fadedOutgoing = applyOpacity(to: outgoing, opacity: 1 - progress)
        let fadedIncoming = applyOpacity(to: incoming, opacity: progress)
        let black = CIImage(color: .black).cropped(to: extent)
        return fadedIncoming.composited(over: fadedOutgoing.composited(over: black)).cropped(to: extent)
    }

    private func applyOpacity(to image: CIImage, opacity: CGFloat) -> CIImage {
        image.applyingFilter(
            "CIColorMatrix",
            parameters: [
                "inputAVector": CIVector(x: 0, y: 0, z: 0, w: opacity)
            ]
        )
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

    private func frameRenderError(code: Int, description: String) -> NSError {
        NSError(
            domain: "FrameCompositor",
            code: code,
            userInfo: [NSLocalizedDescriptionKey: description]
        )
    }
}
