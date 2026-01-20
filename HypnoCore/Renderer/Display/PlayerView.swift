//
//  PlayerView.swift
//  HypnoCore
//
//  MTKView-based display surface for the Metal playback pipeline.
//  Replaces AVPlayerView with a single unified render surface for both
//  Preview and Live displays. Supports shader-based transitions.
//

import AppKit
import MetalKit
import CoreVideo
import CoreMedia
import QuartzCore

/// MTKView subclass that displays video frames as Metal textures.
/// Designed for use with AVPlayerFrameSource to pull frames from AVPlayer.
public final class PlayerView: MTKView {

    // MARK: - Public Properties

    /// Whether the view should render frames (set to false to pause rendering)
    public var isRenderingEnabled: Bool = true

    /// Current aspect ratio mode for content display
    public var contentMode: ContentMode = .aspectFit

    /// Optional focus point in the source content to keep positioned at a target point in the view.
    /// - `anchorNormalized`: normalized source coordinates (0...1), origin at bottom-left.
    /// - `targetNDC`: view coordinates in NDC space (-1...1), origin at center.
    public struct ContentFocus: Sendable, Equatable {
        public enum OverscrollMode: Sendable, Equatable {
            /// Prevent exposing empty edges (traditional aspect-fill/fit clamping).
            case clampToEdges
            /// Allow the content quad to slide past the view edges, revealing the cleared background.
            case allowBlanking
        }

        public var anchorNormalized: CGPoint
        public var targetNDC: CGPoint
        /// Optional normalized source rect (0...1, origin bottom-left) the view should try to keep fully visible.
        /// When provided, offsets are chosen to maximize inclusion of this rect without revealing empty edges.
        public var boundsNormalized: CGRect?
        /// Padding applied to the view bounds in NDC space (0...1). `0` means allow touching edges.
        public var paddingNDC: CGFloat
        public var overscrollMode: OverscrollMode

        public init(
            anchorNormalized: CGPoint,
            targetNDC: CGPoint = CGPoint(x: 0, y: 0),
            boundsNormalized: CGRect? = nil,
            paddingNDC: CGFloat = 0,
            overscrollMode: OverscrollMode = .clampToEdges
        ) {
            self.anchorNormalized = anchorNormalized
            self.targetNDC = targetNDC
            self.boundsNormalized = boundsNormalized
            self.paddingNDC = paddingNDC
            self.overscrollMode = overscrollMode
        }
    }

    /// When set, adjusts the aspect-fit/fill transform offset so `anchorNormalized` appears at `targetNDC`.
    /// Offsets are clamped so content stays within the view bounds for the current `contentMode`.
    public var contentFocus: ContentFocus?

    /// Content display modes
    public enum ContentMode {
        case aspectFit   // Letterbox/pillarbox to fit
        case aspectFill  // Crop to fill
        case stretch     // Ignore aspect ratio
    }

    // MARK: - Frame Sources

    /// Primary frame source (used when not transitioning)
    public var primarySource: FrameSource? {
        didSet {
            textureCache.flush()
        }
    }

    /// Secondary frame source (used during transitions)
    public var secondarySource: FrameSource?

    // MARK: - Transition State

    /// Current transition type (nil when not transitioning)
    public private(set) var activeTransition: TransitionRenderer.TransitionType?

    /// Transition progress (0.0 to 1.0)
    public private(set) var transitionProgress: Float = 0

    /// Transition duration in seconds
    public var transitionDuration: CFTimeInterval = 1.5

    /// Transition start time
    public private(set) var transitionStartTime: CFTimeInterval?

    /// Callback when transition completes
    public var onTransitionComplete: (() -> Void)?

    /// Callback for transition progress updates (0.0 to 1.0)
    public var onTransitionProgress: ((Float) -> Void)?

    /// If false, the view won't auto-swap sources and clear state when progress reaches 1.0.
    /// Useful for mirrored views that should follow an external controller.
    public var autoCompleteTransitions: Bool = true

    // MARK: - Texture Management

    private let textureCache = TextureCache()
    private var currentTexture: MTLTexture?
    private let textureLock = NSLock()

    /// Seed for transition effects (stays constant for one transition)
    public private(set) var transitionSeed: UInt32 = 0

    private var isTransitionCompletionPending: Bool = false
    private var transitionToken: UInt64 = 0

    private static let maxInFlightFrames: Int = 3
    private let inFlightSemaphore = DispatchSemaphore(value: maxInFlightFrames)
    private var inFlightIndex: Int = 0

    private var transitionOutputTextures: [MTLTexture] = []
    private var yuvConvertedTextures: [MTLTexture] = []

    /// Set the texture to display directly (bypasses frame sources)
    public func setTexture(_ texture: MTLTexture?) {
        textureLock.lock()
        currentTexture = texture
        textureLock.unlock()
    }

    // MARK: - Metal Resources

    private var commandQueue: MTLCommandQueue?
    private var renderPipelineState: MTLRenderPipelineState?
    private var yuvToRGBAPipelineState: MTLComputePipelineState?
    private var samplerState: MTLSamplerState?
    private var vertexBuffer: MTLBuffer?
    private var transitionRenderer: TransitionRenderer?
    private var shaderLibrary: MTLLibrary?

    // YUV conversion parameters
    private struct YUVParams {
        var width: Int32
        var height: Int32
        var useBT709: Int32 = 1     // Default to BT.709 (HD content)
        var isVideoRange: Int32 = 1  // Default to video range
        var isTenBit: Int32 = 0
    }

    // MARK: - Initialization

    public override init(frame frameRect: CGRect, device: MTLDevice?) {
        super.init(frame: frameRect, device: device ?? SharedRenderer.metalDevice)
        configure()
    }

    public required init(coder: NSCoder) {
        super.init(coder: coder)
        self.device = SharedRenderer.metalDevice
        configure()
    }

    private func configure() {
        guard let device = self.device else {
            print("PlayerView: No Metal device available")
            return
        }

        // MTKView configuration
        colorPixelFormat = .bgra8Unorm
        framebufferOnly = true
        isPaused = false
        enableSetNeedsDisplay = false
        preferredFramesPerSecond = 60
        clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)

        // Create command queue
        commandQueue = device.makeCommandQueue()

        // Setup render pipeline and resources
        setupRenderPipelines()
        setupSampler()
        setupVertexBuffer()

        // Create transition renderer
        transitionRenderer = TransitionRenderer(device: device)
    }

    // MARK: - Pipeline Setup

    private func setupRenderPipelines() {
        guard let device = device else { return }

        let library: MTLLibrary?
        do {
            library = try device.makeDefaultLibrary(bundle: Bundle(for: PlayerView.self))
        } catch {
            print("PlayerView: Failed to load shader library: \(error)")
            return
        }

        guard let lib = library else {
            print("PlayerView: No shader library found")
            return
        }
        shaderLibrary = lib

        // Passthrough pipeline (BGRA textures)
        setupPassthroughPipeline(library: lib)

        // YUV conversion compute pipeline (optional)
        if let function = lib.makeFunction(name: "yuvToRGBA") {
            yuvToRGBAPipelineState = try? device.makeComputePipelineState(function: function)
        }
    }

    private func setupPassthroughPipeline(library: MTLLibrary) {
        guard let device = device else { return }

        guard let vertexFunction = library.makeFunction(name: "passthroughVertex"),
              let fragmentFunction = library.makeFunction(name: "passthroughFragment") else {
            print("PlayerView: Passthrough shader functions not found")
            return
        }

        let descriptor = MTLRenderPipelineDescriptor()
        descriptor.vertexFunction = vertexFunction
        descriptor.fragmentFunction = fragmentFunction
        descriptor.colorAttachments[0].pixelFormat = colorPixelFormat

        descriptor.colorAttachments[0].isBlendingEnabled = true
        descriptor.colorAttachments[0].sourceRGBBlendFactor = .sourceAlpha
        descriptor.colorAttachments[0].destinationRGBBlendFactor = .oneMinusSourceAlpha
        descriptor.colorAttachments[0].sourceAlphaBlendFactor = .one
        descriptor.colorAttachments[0].destinationAlphaBlendFactor = .oneMinusSourceAlpha

        do {
            renderPipelineState = try device.makeRenderPipelineState(descriptor: descriptor)
        } catch {
            print("PlayerView: Failed to create passthrough pipeline: \(error)")
        }
    }

    private func setupSampler() {
        guard let device = device else { return }

        let descriptor = MTLSamplerDescriptor()
        descriptor.minFilter = .linear
        descriptor.magFilter = .linear
        descriptor.mipFilter = .notMipmapped
        descriptor.sAddressMode = .clampToEdge
        descriptor.tAddressMode = .clampToEdge

        samplerState = device.makeSamplerState(descriptor: descriptor)
    }

    private func setupVertexBuffer() {
        guard let device = device else { return }

        // Fullscreen quad vertices as packed float4 (posX, posY, texU, texV)
        // NDC: (-1,-1) = bottom-left, (1,1) = top-right
        // Texture coords: (0,0) = top-left, (1,1) = bottom-right
        // So bottom-left vertex (-1,-1) maps to texture (0,1)
        // And top-right vertex (1,1) maps to texture (1,0)
        let vertices: [SIMD4<Float>] = [
            // Triangle 1: bottom-left, bottom-right, top-left
            SIMD4(-1, -1, 0, 1),  // bottom-left  -> tex (0,1)
            SIMD4( 1, -1, 1, 1),  // bottom-right -> tex (1,1)
            SIMD4(-1,  1, 0, 0),  // top-left     -> tex (0,0)
            // Triangle 2: bottom-right, top-right, top-left
            SIMD4( 1, -1, 1, 1),  // bottom-right -> tex (1,1)
            SIMD4( 1,  1, 1, 0),  // top-right    -> tex (1,0)
            SIMD4(-1,  1, 0, 0),  // top-left     -> tex (0,0)
        ]

        vertexBuffer = device.makeBuffer(
            bytes: vertices,
            length: vertices.count * MemoryLayout<SIMD4<Float>>.stride,
            options: .storageModeShared
        )
    }

    // MARK: - Transitions

    /// Start a transition to a new frame source
    public func startTransition(
        to newSource: FrameSource,
        type: TransitionRenderer.TransitionType,
        duration: CFTimeInterval? = nil,
        seed: UInt32? = nil,
        startTime: CFTimeInterval? = nil
    ) {
        transitionToken &+= 1
        secondarySource = newSource
        activeTransition = type
        transitionDuration = duration ?? self.transitionDuration
        // If `startTime` is nil, defer starting progress until we can actually render
        // (i.e., we have both outgoing and incoming textures). This avoids transitions
        // that appear to "cut" because the incoming source hasn't produced a frame yet.
        transitionStartTime = startTime
        transitionProgress = 0
        isTransitionCompletionPending = false
        // Generate a fresh seed for this transition (stays constant throughout)
        transitionSeed = seed ?? UInt32.random(in: 0...UInt32.max)
    }

    /// Apply externally-controlled transition state (for mirrored views).
    public func setTransitionState(
        secondarySource: FrameSource?,
        type: TransitionRenderer.TransitionType?,
        startTime: CFTimeInterval?,
        duration: CFTimeInterval,
        seed: UInt32
    ) {
        transitionToken &+= 1
        self.secondarySource = secondarySource
        self.activeTransition = type
        self.transitionStartTime = startTime
        self.transitionDuration = duration
        self.transitionSeed = seed
        self.isTransitionCompletionPending = false
    }

    /// Cancel an in-progress transition
    public func cancelTransition() {
        transitionToken &+= 1
        secondarySource = nil
        activeTransition = nil
        transitionStartTime = nil
        transitionProgress = 0
        isTransitionCompletionPending = false
    }

    // MARK: - Drawing

    public override func draw(_ dirtyRect: NSRect) {
        guard isRenderingEnabled else { return }

        inFlightSemaphore.wait()

        guard let commandBuffer = commandQueue?.makeCommandBuffer() else {
            inFlightSemaphore.signal()
            return
        }

        let frameIndex = inFlightIndex
        inFlightIndex = (inFlightIndex + 1) % Self.maxInFlightFrames

        commandBuffer.addCompletedHandler { [weak self] _ in
            self?.inFlightSemaphore.signal()
        }

        let hostTime = CACurrentMediaTime()

        // Get frames from sources
        let primaryFrame = primarySource?.bestFrame(forHostTime: hostTime)
        let secondaryFrame = secondarySource?.bestFrame(forHostTime: hostTime)

        // Convert to textures
        let primaryTexture = primaryFrame.flatMap { frameToTexture($0, commandBuffer: commandBuffer, frameIndex: frameIndex) }
        let secondaryTexture = secondaryFrame.flatMap { frameToTexture($0, commandBuffer: commandBuffer, frameIndex: frameIndex) }

        // Determine what to render
        textureLock.lock()
        let directTexture = currentTexture
        textureLock.unlock()

        // If this transition was started without an explicit `startTime`, begin counting
        // progress only once we have both textures needed to render it.
        if activeTransition != nil,
           transitionStartTime == nil,
           (primaryTexture ?? directTexture) != nil,
           secondaryTexture != nil {
            transitionStartTime = hostTime
            transitionProgress = 0
            isTransitionCompletionPending = false
        }

        // Update transition progress (may return a completion callback)
        let transitionCompletion = updateTransition(now: hostTime)

        let outputTexture: MTLTexture?

        if let transition = activeTransition,
           let outgoing = primaryTexture ?? directTexture,
           let incoming = secondaryTexture {
            // Render transition
            outputTexture = renderTransition(
                outgoing: outgoing,
                incoming: incoming,
                type: transition,
                progress: transitionProgress,
                commandBuffer: commandBuffer,
                frameIndex: frameIndex
            )
        } else {
            // Use primary texture or direct texture
            outputTexture = primaryTexture ?? directTexture
        }

        // Render to screen
        renderToScreen(texture: outputTexture, commandBuffer: commandBuffer)

        if let transitionCompletion {
            commandBuffer.addCompletedHandler { _ in
                DispatchQueue.main.async {
                    transitionCompletion()
                }
            }
        }

        commandBuffer.commit()
    }

    private func updateTransition(now: CFTimeInterval) -> (() -> Void)? {
        guard activeTransition != nil, let startTime = transitionStartTime else { return nil }
        let token = transitionToken

        let elapsed = now - startTime
        let progress = Float(min(max(elapsed / max(transitionDuration, 0.0001), 0), 1.0))
        transitionProgress = progress

        if let onTransitionProgress {
            if Thread.isMainThread {
                onTransitionProgress(progress)
            } else {
                DispatchQueue.main.async {
                    onTransitionProgress(progress)
                }
            }
        }

        guard progress >= 1.0 else {
            isTransitionCompletionPending = false
            return nil
        }
        guard autoCompleteTransitions else { return nil }
        guard !isTransitionCompletionPending else { return nil }

        isTransitionCompletionPending = true
        let completion = onTransitionComplete
        onTransitionComplete = nil
        return { [weak self] in
            guard let self else { return }
            guard self.transitionToken == token else { return }
            self.primarySource = self.secondarySource
            self.secondarySource = nil
            self.activeTransition = nil
            self.transitionStartTime = nil
            self.transitionProgress = 0
            self.isTransitionCompletionPending = false
            completion?()
        }
    }

    private func frameToTexture(_ frame: DecodedFrame, commandBuffer: MTLCommandBuffer, frameIndex: Int) -> MTLTexture? {
        if frame.isYUV {
            return convertYUVToRGBA(frame, commandBuffer: commandBuffer, frameIndex: frameIndex)
        } else {
            return textureCache.texture(from: frame.pixelBuffer)
        }
    }

    private func ensureInFlightTexturesMatch(
        textures: inout [MTLTexture],
        width: Int,
        height: Int,
        usage: MTLTextureUsage
    ) {
        guard let device else { return }
        guard textures.count == Self.maxInFlightFrames,
              textures.first?.width == width,
              textures.first?.height == height else {
            let descriptor = MTLTextureDescriptor.texture2DDescriptor(
                pixelFormat: .bgra8Unorm,
                width: width,
                height: height,
                mipmapped: false
            )
            descriptor.usage = usage
            textures = (0..<Self.maxInFlightFrames).compactMap { _ in
                device.makeTexture(descriptor: descriptor)
            }
            return
        }
    }

    private func convertYUVToRGBA(_ frame: DecodedFrame, commandBuffer: MTLCommandBuffer, frameIndex: Int) -> MTLTexture? {
        guard let yuvTextures = textureCache.yuvTextures(from: frame.pixelBuffer),
              let pipeline = yuvToRGBAPipelineState else {
            return nil
        }

        ensureInFlightTexturesMatch(
            textures: &yuvConvertedTextures,
            width: frame.width,
            height: frame.height,
            usage: [.shaderRead, .shaderWrite]
        )

        guard yuvConvertedTextures.count == Self.maxInFlightFrames else { return nil }
        let outputTexture = yuvConvertedTextures[frameIndex]

        guard let encoder = commandBuffer.makeComputeCommandEncoder() else {
            return nil
        }

        encoder.setComputePipelineState(pipeline)
        encoder.setTexture(yuvTextures.y, index: 0)
        encoder.setTexture(yuvTextures.cbcr, index: 1)
        encoder.setTexture(outputTexture, index: 2)

        var params = YUVParams(
            width: Int32(frame.width),
            height: Int32(frame.height),
            useBT709: 1,
            isVideoRange: yuvTextures.isVideoRange ? 1 : 0,
            isTenBit: yuvTextures.isTenBit ? 1 : 0
        )
        encoder.setBytes(&params, length: MemoryLayout<YUVParams>.size, index: 0)

        let threadgroupSize = MTLSize(width: 16, height: 16, depth: 1)
        let threadgroups = MTLSize(
            width: (frame.width + 15) / 16,
            height: (frame.height + 15) / 16,
            depth: 1
        )
        encoder.dispatchThreadgroups(threadgroups, threadsPerThreadgroup: threadgroupSize)
        encoder.endEncoding()

        return outputTexture
    }

    private func renderTransition(
        outgoing: MTLTexture,
        incoming: MTLTexture,
        type: TransitionRenderer.TransitionType,
        progress: Float,
        commandBuffer: MTLCommandBuffer,
        frameIndex: Int
    ) -> MTLTexture? {
        // Create or reuse output texture
        let width = max(outgoing.width, incoming.width)
        let height = max(outgoing.height, incoming.height)

        ensureInFlightTexturesMatch(
            textures: &transitionOutputTextures,
            width: width,
            height: height,
            usage: [.shaderRead, .shaderWrite]
        )

        guard transitionOutputTextures.count == Self.maxInFlightFrames else { return nil }
        let output = transitionOutputTextures[frameIndex]

        transitionRenderer?.render(
            outgoing: outgoing,
            incoming: incoming,
            output: output,
            type: type,
            progress: progress,
            seed: transitionSeed,
            commandBuffer: commandBuffer
        )

        return output
    }

    private func renderToScreen(texture: MTLTexture?, commandBuffer: MTLCommandBuffer) {
        guard let drawable = currentDrawable,
              let renderPassDescriptor = currentRenderPassDescriptor,
              let pipelineState = renderPipelineState else {
            return
        }

        renderPassDescriptor.colorAttachments[0].loadAction = .clear
        renderPassDescriptor.colorAttachments[0].storeAction = .store

        guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: renderPassDescriptor) else {
            return
        }

        if let texture = texture {
            encoder.setRenderPipelineState(pipelineState)
            encoder.setVertexBuffer(vertexBuffer, offset: 0, index: 0)

            var transform = calculateTransform(textureSize: CGSize(width: texture.width, height: texture.height))
            encoder.setVertexBytes(&transform, length: MemoryLayout<SIMD4<Float>>.size, index: 1)

            encoder.setFragmentTexture(texture, index: 0)
            encoder.setFragmentSamplerState(samplerState, index: 0)

            encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 6)
        }

        encoder.endEncoding()
        commandBuffer.present(drawable)
    }

    // MARK: - Aspect Ratio Handling

    private func calculateTransform(textureSize: CGSize) -> SIMD4<Float> {
        let viewSize = bounds.size
        guard viewSize.width > 0, viewSize.height > 0,
              textureSize.width > 0, textureSize.height > 0 else {
            return SIMD4(1, 1, 0, 0)
        }

        let viewAspect = viewSize.width / viewSize.height
        let textureAspect = textureSize.width / textureSize.height

        var scaleX: Float = 1.0
        var scaleY: Float = 1.0

        switch contentMode {
        case .aspectFit:
            if textureAspect > viewAspect {
                scaleY = Float(viewAspect / textureAspect)
            } else {
                scaleX = Float(textureAspect / viewAspect)
            }

        case .aspectFill:
            if textureAspect > viewAspect {
                scaleX = Float(textureAspect / viewAspect)
            } else {
                scaleY = Float(viewAspect / textureAspect)
            }

        case .stretch:
            break
        }

        func clamp(_ value: Float, _ minValue: Float, _ maxValue: Float) -> Float {
            max(minValue, min(maxValue, value))
        }

        var offsetX: Float = 0
        var offsetY: Float = 0

        if let focus = contentFocus {
            let anchorX = clamp(Float(focus.anchorNormalized.x), 0, 1)
            let anchorY = clamp(Float(focus.anchorNormalized.y), 0, 1)
            let targetX = clamp(Float(focus.targetNDC.x), -1, 1)
            let targetY = clamp(Float(focus.targetNDC.y), -1, 1)

            // Mapping (normalized content -> view):
            // contentX = (1 + (viewX - offsetX) / scaleX) / 2
            // contentY = (1 + (viewY - offsetY) / scaleY) / 2
            // Solve for offset so the anchor appears at the target.
            let rawOffsetX = targetX - scaleX * (2 * anchorX - 1)
            let rawOffsetY = targetY - scaleY * (2 * anchorY - 1)

            // Clamp offsets so content stays in-bounds (fit) or continues to cover the view (fill).
            let maxOffsetX: Float
            let maxOffsetY: Float
            switch focus.overscrollMode {
            case .clampToEdges:
                maxOffsetX = abs(scaleX - 1)
                maxOffsetY = abs(scaleY - 1)
            case .allowBlanking:
                // Allow shifting until the quad is just barely still intersecting the view.
                // Over-shifting reveals the cleared background (black).
                maxOffsetX = abs(scaleX + 1)
                maxOffsetY = abs(scaleY + 1)
            }

            offsetX = clamp(rawOffsetX, -maxOffsetX, maxOffsetX)
            offsetY = clamp(rawOffsetY, -maxOffsetY, maxOffsetY)

            if let bounds = focus.boundsNormalized {
                let pad = clamp(Float(focus.paddingNDC), 0, 1)

                // Keep the rect within padded NDC bounds where possible.
                // For a given normalized content coordinate y, viewY = scaleY*(2y - 1) + offsetY.
                let minX = clamp(Float(bounds.minX), 0, 1)
                let maxX = clamp(Float(bounds.maxX), 0, 1)
                let minY = clamp(Float(bounds.minY), 0, 1)
                let maxY = clamp(Float(bounds.maxY), 0, 1)

                // Constraints:
                // viewX(minX) >= -1 + pad  => offsetX >= (-1 + pad) - scaleX*(2*minX - 1)
                // viewX(maxX) <=  1 - pad  => offsetX <= ( 1 - pad) - scaleX*(2*maxX - 1)
                // Same for Y.
                let lowerX = (-1 + pad) - scaleX * (2 * minX - 1)
                let upperX = ( 1 - pad) - scaleX * (2 * maxX - 1)
                let lowerY = (-1 + pad) - scaleY * (2 * minY - 1)
                let upperY = ( 1 - pad) - scaleY * (2 * maxY - 1)

                // Intersect with global clamp range. If empty (rect larger than visible region),
                // keep current offset (already clamped) which maximizes coverage without overscroll.
                let finalLowerX = max(-maxOffsetX, lowerX)
                let finalUpperX = min( maxOffsetX, upperX)
                if finalLowerX <= finalUpperX {
                    offsetX = clamp(offsetX, finalLowerX, finalUpperX)
                }

                let finalLowerY = max(-maxOffsetY, lowerY)
                let finalUpperY = min( maxOffsetY, upperY)
                if finalLowerY <= finalUpperY {
                    offsetY = clamp(offsetY, finalLowerY, finalUpperY)
                }
            }
        }

        return SIMD4(scaleX, scaleY, offsetX, offsetY)
    }
}
