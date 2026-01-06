//
//  StillImageCache.swift
//  Hypnograph
//
//  Created by Loren Johnson on 25.11.25.
//

import CoreImage
import CoreGraphics
import ImageIO

/// Lightweight cache so we only ever try to decode a still image once per URL.
/// This avoids repeated slow disk/decoder work and repeated CGImageSource errors.
/// NOTE: Cache grows unbounded - call clear() periodically to free memory.
public enum StillImageCache {
    private static var ciCache: [URL: CIImage?] = [:]
    private static var cgCache: [URL: CGImage?] = [:]
    private static let lock = NSLock()

    // Shared context for rendering CIImages to proper pixel format
    private static let ciContext = CIContext(options: [
        .useSoftwareRenderer: false,
        .cacheIntermediates: false
    ])

    /// Clear all cached images to free memory
    public static func clear() {
        lock.lock(); defer { lock.unlock() }
        ciCache.removeAll()
        cgCache.removeAll()
        print("🧹 StillImageCache: Cleared all cached images")
    }

    /// Get current cache size (number of cached images)
    public static func cacheSize() -> (ciImages: Int, cgImages: Int) {
        lock.lock(); defer { lock.unlock() }
        return (ciCache.count, cgCache.count)
    }

    public static func ciImage(for url: URL) -> CIImage? {
        lock.lock(); defer { lock.unlock() }

        if let cached = ciCache[url] { return cached }

        // Check file existence first to avoid noisy errors
        guard FileManager.default.fileExists(atPath: url.path) else {
            print("❌ StillImageCache: File not found: \(url.lastPathComponent)")
            ciCache[url] = nil
            return nil
        }

        // ALWAYS go through CGImage first to ensure proper pixel format decoding.
        // CIImage(contentsOf:) can create JPEG-backed images that cause IOSurface
        // creation failures with error e00002c2 when the compositor tries to render.
        // CGImageSource properly decodes to a usable pixel format.
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil) else {
            print("❌ StillImageCache: Failed to create image source for \(url.lastPathComponent)")
            ciCache[url] = nil
            return nil
        }

        // Get orientation from EXIF metadata
        let properties = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any]
        let orientationValue = properties?[kCGImagePropertyOrientation] as? UInt32 ?? 1
        let orientation = CGImagePropertyOrientation(rawValue: orientationValue) ?? .up

        // Request immediate decoding to avoid lazy JPEG-backed data
        let decodeOptions: [CFString: Any] = [
            kCGImageSourceShouldCacheImmediately: true
        ]
        guard let cgImage = CGImageSourceCreateImageAtIndex(src, 0, decodeOptions as CFDictionary) else {
            print("❌ StillImageCache: Failed to decode CGImage from \(url.lastPathComponent)")
            ciCache[url] = nil
            return nil
        }

        // Create CIImage with proper orientation applied
        var ci = CIImage(cgImage: cgImage)
        ci = ci.oriented(orientation)

        ciCache[url] = ci
        return ci
    }

    public static func cgImage(for url: URL) -> CGImage? {
        lock.lock(); defer { lock.unlock() }

        if let cached = cgCache[url] { return cached }

        // Suppress CGImageSource errors by checking file existence first
        guard FileManager.default.fileExists(atPath: url.path) else {
            print("❌ StillImageCache: File not found: \(url.lastPathComponent)")
            cgCache[url] = nil
            return nil
        }

        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
              let img = CGImageSourceCreateImageAtIndex(src, 0, nil) else {
            // Only log once per URL (cache the nil result)
            print("❌ StillImageCache: Failed to decode CGImage from \(url.lastPathComponent)")
            cgCache[url] = nil
            return nil
        }

        cgCache[url] = img
        return img
    }
}
