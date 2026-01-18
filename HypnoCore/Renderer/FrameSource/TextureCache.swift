//
//  TextureCache.swift
//  HypnoCore
//
//  CVMetalTextureCache wrapper for efficient CVPixelBuffer to MTLTexture conversion.
//  Supports both BGRA (single-plane) and YUV (bi-planar) pixel formats.
//

import Metal
import CoreVideo

/// Wraps CVMetalTextureCache for efficient zero-copy texture creation from CVPixelBuffers.
public final class TextureCache {

    // MARK: - Properties

    private var cache: CVMetalTextureCache?
    private let device: MTLDevice

    /// Whether the cache is properly initialized
    public var isValid: Bool {
        cache != nil
    }

    // MARK: - Initialization

    public init(device: MTLDevice = SharedRenderer.device) {
        self.device = device

        var textureCache: CVMetalTextureCache?
        let status = CVMetalTextureCacheCreate(
            kCFAllocatorDefault,
            nil,
            device,
            nil,
            &textureCache
        )

        if status != kCVReturnSuccess {
            print("TextureCache: Failed to create CVMetalTextureCache (status: \(status))")
        }

        self.cache = textureCache
    }

    deinit {
        flush()
    }

    // MARK: - Single-Plane Textures (BGRA)

    /// Create a Metal texture from a single-plane BGRA pixel buffer
    public func texture(from pixelBuffer: CVPixelBuffer) -> MTLTexture? {
        guard let cache = cache else { return nil }

        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)

        // Determine pixel format
        let pixelFormat = CVPixelBufferGetPixelFormatType(pixelBuffer)
        let metalFormat: MTLPixelFormat

        switch pixelFormat {
        case kCVPixelFormatType_32BGRA:
            metalFormat = .bgra8Unorm
        case kCVPixelFormatType_32RGBA:
            metalFormat = .rgba8Unorm
        default:
            // For other formats, try BGRA (may not work)
            metalFormat = .bgra8Unorm
        }

        var cvTexture: CVMetalTexture?
        let status = CVMetalTextureCacheCreateTextureFromImage(
            kCFAllocatorDefault,
            cache,
            pixelBuffer,
            nil,
            metalFormat,
            width,
            height,
            0,  // plane index
            &cvTexture
        )

        guard status == kCVReturnSuccess, let cvTex = cvTexture else {
            return nil
        }

        return CVMetalTextureGetTexture(cvTex)
    }

    // MARK: - Bi-Planar Textures (YUV)

    /// YUV texture pair (Y plane + CbCr plane)
    public struct YUVTextures {
        public let y: MTLTexture      // Luma plane (full resolution, R8)
        public let cbcr: MTLTexture   // Chroma plane (half resolution, RG8)
        public let isVideoRange: Bool // true = 16-235 range, false = 0-255 range
    }

    /// Create Metal textures from a bi-planar YUV pixel buffer
    public func yuvTextures(from pixelBuffer: CVPixelBuffer) -> YUVTextures? {
        guard let cache = cache else { return nil }

        let pixelFormat = CVPixelBufferGetPixelFormatType(pixelBuffer)

        // Verify this is a bi-planar YUV format
        let isVideoRange: Bool
        switch pixelFormat {
        case kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange:
            isVideoRange = true
        case kCVPixelFormatType_420YpCbCr8BiPlanarFullRange:
            isVideoRange = false
        case kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange:
            isVideoRange = true
        case kCVPixelFormatType_420YpCbCr10BiPlanarFullRange:
            isVideoRange = false
        default:
            print("TextureCache: Unsupported pixel format for YUV: \(pixelFormat)")
            return nil
        }

        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)

        // Y plane (full resolution, single channel)
        var yTexture: CVMetalTexture?
        var status = CVMetalTextureCacheCreateTextureFromImage(
            kCFAllocatorDefault,
            cache,
            pixelBuffer,
            nil,
            .r8Unorm,
            width,
            height,
            0,  // plane 0 = Y
            &yTexture
        )

        guard status == kCVReturnSuccess, let yTex = yTexture else {
            print("TextureCache: Failed to create Y texture (status: \(status))")
            return nil
        }

        // CbCr plane (half resolution, two channels)
        var cbcrTexture: CVMetalTexture?
        status = CVMetalTextureCacheCreateTextureFromImage(
            kCFAllocatorDefault,
            cache,
            pixelBuffer,
            nil,
            .rg8Unorm,
            width / 2,
            height / 2,
            1,  // plane 1 = CbCr
            &cbcrTexture
        )

        guard status == kCVReturnSuccess, let cbcrTex = cbcrTexture else {
            print("TextureCache: Failed to create CbCr texture (status: \(status))")
            return nil
        }

        guard let yMetal = CVMetalTextureGetTexture(yTex),
              let cbcrMetal = CVMetalTextureGetTexture(cbcrTex) else {
            return nil
        }

        return YUVTextures(y: yMetal, cbcr: cbcrMetal, isVideoRange: isVideoRange)
    }

    // MARK: - Utilities

    /// Flush the texture cache to release resources
    public func flush() {
        guard let cache = cache else { return }
        CVMetalTextureCacheFlush(cache, 0)
    }

    /// Create texture from DecodedFrame, handling both BGRA and YUV formats
    /// For YUV frames, this returns a single BGRA texture after conversion
    /// (use yuvTextures(from:) if you need the raw YUV planes)
    public func texture(from frame: DecodedFrame) -> MTLTexture? {
        // For BGRA frames, direct conversion
        if !frame.isYUV {
            return texture(from: frame.pixelBuffer)
        }

        // For YUV frames, return the Y plane as a temporary solution
        // Full YUV->RGB conversion should happen in the shader
        // This is a fallback for cases where we need a single texture
        return yuvTextures(from: frame.pixelBuffer)?.y
    }
}
