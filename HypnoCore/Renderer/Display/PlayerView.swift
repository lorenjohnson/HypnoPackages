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

/// MTKView subclass that displays video frames as Metal textures.
/// Designed for use with AVPlayerFrameSource to pull frames from AVPlayer.
public final class PlayerView: MTKView {

    // MARK: - Public Properties

    /// Whether the view should render frames (set to false to pause rendering)
    public var isRenderingEnabled: Bool = true

    /// Current aspect ratio mode for content display
    public var contentMode: ContentMode = .aspectFit

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
    private var transitionStartTime: CFTimeInterval?

    /// Callback when transition completes
    public var onTransitionComplete: (() -> Void)?

    // MARK: - Texture Management

    private let textureCache = TextureCache()
    private var currentTexture: MTLTexture?
    private var transitionOutputTexture: MTLTexture?
    private let textureLock = NSLock()

    /// Seed for transition effects (stays constant for one transition)
    private var transitionSeed: UInt32 = 0

    /// Set the texture to display directly (bypasses frame sources)
    public func setTexture(_ texture: MTLTexture?) {
        textureLock.lock()
        currentTexture = texture
        textureLock.unlock()
    }

    // MARK: - Metal Resources

    private var commandQueue: MTLCommandQueue?
    private var renderPipelineState: MTLRenderPipelineState?
    private var yuvRenderPipelineState: MTLRenderPipelineState?
    private var samplerState: MTLSamplerState?
    private var vertexBuffer: MTLBuffer?
    private var transitionRenderer: TransitionRenderer?

    // YUV conversion parameters
    private struct YUVParams {
        var width: Int32
        var height: Int32
        var useBT709: Int32 = 1     // Default to BT.709 (HD content)
        var isVideoRange: Int32 = 1  // Default to video range
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
        framebufferOnly = false  // Need to read back for transitions
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

        // Passthrough pipeline (BGRA textures)
        setupPassthroughPipeline(library: lib)

        // YUV pipeline
        setupYUVPipeline(library: lib)
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

    private func setupYUVPipeline(library: MTLLibrary) {
        guard let device = device else { return }

        guard let vertexFunction = library.makeFunction(name: "yuvDisplayVertex"),
              let fragmentFunction = library.makeFunction(name: "yuvDisplayFragment") else {
            print("PlayerView: YUV shader functions not found")
            return
        }

        let descriptor = MTLRenderPipelineDescriptor()
        descriptor.vertexFunction = vertexFunction
        descriptor.fragmentFunction = fragmentFunction
        descriptor.colorAttachments[0].pixelFormat = colorPixelFormat

        do {
            yuvRenderPipelineState = try device.makeRenderPipelineState(descriptor: descriptor)
        } catch {
            print("PlayerView: Failed to create YUV pipeline: \(error)")
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
        duration: CFTimeInterval? = nil
    ) {
        secondarySource = newSource
        activeTransition = type
        transitionDuration = duration ?? self.transitionDuration
        transitionStartTime = CACurrentMediaTime()
        transitionProgress = 0
        // Generate a fresh seed for this transition (stays constant throughout)
        transitionSeed = UInt32.random(in: 0...UInt32.max)
    }

    /// Cancel an in-progress transition
    public func cancelTransition() {
        secondarySource = nil
        activeTransition = nil
        transitionStartTime = nil
        transitionProgress = 0
    }

    // MARK: - Drawing

    public override func draw(_ dirtyRect: NSRect) {
        guard isRenderingEnabled else { return }

        guard let commandBuffer = commandQueue?.makeCommandBuffer() else { return }

        // Update transition progress
        updateTransition()

        // Get frames from sources
        let primaryFrame = primarySource?.bestFrame(for: primarySource?.currentTime ?? .zero)
        let secondaryFrame = secondarySource?.bestFrame(for: secondarySource?.currentTime ?? .zero)

        // Convert to textures
        let primaryTexture = primaryFrame.flatMap { frameToTexture($0) }
        let secondaryTexture = secondaryFrame.flatMap { frameToTexture($0) }

        // Determine what to render
        textureLock.lock()
        let directTexture = currentTexture
        textureLock.unlock()

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
                commandBuffer: commandBuffer
            )
        } else {
            // Debug: log when transition should be active but textures are missing
            if activeTransition != nil {
                let hasOutgoing = (primaryTexture ?? directTexture) != nil
                let hasIncoming = secondaryTexture != nil
                if !hasOutgoing || !hasIncoming {
                    print("PlayerView: Transition \(activeTransition!) stalled - outgoing=\(hasOutgoing) incoming=\(hasIncoming) progress=\(transitionProgress)")
                }
            }
            // Use primary texture or direct texture
            outputTexture = primaryTexture ?? directTexture
        }

        // Render to screen
        renderToScreen(texture: outputTexture, commandBuffer: commandBuffer)

        commandBuffer.commit()
    }

    private func updateTransition() {
        guard let startTime = transitionStartTime else { return }

        let elapsed = CACurrentMediaTime() - startTime
        transitionProgress = Float(min(elapsed / transitionDuration, 1.0))

        if transitionProgress >= 1.0 {
            // Transition complete
            primarySource = secondarySource
            secondarySource = nil
            activeTransition = nil
            transitionStartTime = nil
            transitionProgress = 0

            onTransitionComplete?()
        }
    }

    private func frameToTexture(_ frame: DecodedFrame) -> MTLTexture? {
        if frame.isYUV {
            // For YUV frames, we need to convert to RGBA
            // Use compute shader for conversion
            return convertYUVToRGBA(frame)
        } else {
            return textureCache.texture(from: frame.pixelBuffer)
        }
    }

    private func convertYUVToRGBA(_ frame: DecodedFrame) -> MTLTexture? {
        guard let device = device,
              let commandQueue = commandQueue,
              let yuvTextures = textureCache.yuvTextures(from: frame.pixelBuffer) else {
            return nil
        }

        // Create output texture
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .bgra8Unorm,
            width: frame.width,
            height: frame.height,
            mipmapped: false
        )
        descriptor.usage = [.shaderRead, .shaderWrite]

        guard let outputTexture = device.makeTexture(descriptor: descriptor) else {
            return nil
        }

        // Load compute shader
        guard let library = try? device.makeDefaultLibrary(bundle: Bundle(for: PlayerView.self)),
              let function = library.makeFunction(name: "yuvToRGBA"),
              let pipeline = try? device.makeComputePipelineState(function: function) else {
            return nil
        }

        guard let commandBuffer = commandQueue.makeCommandBuffer(),
              let encoder = commandBuffer.makeComputeCommandEncoder() else {
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
            isVideoRange: yuvTextures.isVideoRange ? 1 : 0
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

        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()

        return outputTexture
    }

    private func renderTransition(
        outgoing: MTLTexture,
        incoming: MTLTexture,
        type: TransitionRenderer.TransitionType,
        progress: Float,
        commandBuffer: MTLCommandBuffer
    ) -> MTLTexture? {
        guard let device = device else { return nil }

        // Create or reuse output texture
        let width = max(outgoing.width, incoming.width)
        let height = max(outgoing.height, incoming.height)

        if transitionOutputTexture == nil ||
           transitionOutputTexture!.width != width ||
           transitionOutputTexture!.height != height {
            let descriptor = MTLTextureDescriptor.texture2DDescriptor(
                pixelFormat: .bgra8Unorm,
                width: width,
                height: height,
                mipmapped: false
            )
            descriptor.usage = [.shaderRead, .shaderWrite]
            transitionOutputTexture = device.makeTexture(descriptor: descriptor)
        }

        guard let output = transitionOutputTexture else { return nil }

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

        return SIMD4(scaleX, scaleY, 0, 0)
    }
}
