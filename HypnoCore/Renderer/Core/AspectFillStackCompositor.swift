//
//  AspectFillStackCompositor.swift
//  Hypnograph
//
//  Shared Core Image compositing for preview + render.
//  First wired into AVFoundation export; later reused for live preview.
//

import Foundation
import CoreImage
import CoreGraphics

/// Small helper that knows how to:
/// - resize each layer image to "fill" the target (aspect-fill, center crop)
/// - apply Core Image blend filters in order
/// - return a single CIImage ready to render
struct AspectFillStackCompositor {

    /// Compose a stack of CIImages using CI blend filters.
    ///
    /// - Parameters:
    ///   - images:      [bottom, ..., top]
    ///   - blendModes:  CI filter names (e.g. "CIMultiplyBlendMode").
    ///                  Index 0 is the base; ignored except as a sanity check.
    ///   - targetSize:  render size in pixels.
    func composite(
        images: [CIImage],
        blendModes: [String],
        targetSize: CGSize
    ) -> CIImage {
        guard !images.isEmpty else {
            return CIImage(color: .black).cropped(
                to: CGRect(origin: .zero, size: targetSize)
            )
        }

        // Base layer: scaled to fill.
        var output = resizedToFill(images[0], targetSize: targetSize)

        guard images.count > 1 else {
            return output
        }

        // Blend each additional image onto the base.
        for (index, rawTop) in images.dropFirst().enumerated() {
            let top = resizedToFill(rawTop, targetSize: targetSize)

            let modeName: String
            if index + 1 < blendModes.count {
                modeName = blendModes[index + 1]
            } else {
                modeName = blendModes.last ?? "CISourceOverCompositing"
            }

            output = composite(bottom: output, top: top, modeName: modeName)
        }

        return output
    }

    // MARK: - Internal helpers

    private func composite(bottom: CIImage, top: CIImage, modeName: String) -> CIImage {
        guard let filter = CIFilter(name: modeName) else {
            print("AspectFillStackCompositor: unknown blend filter '\(modeName)', falling back to source-over")
            return top.composited(over: bottom)
        }

        filter.setValue(top, forKey: kCIInputImageKey)
        filter.setValue(bottom, forKey: kCIInputBackgroundImageKey)

        return filter.outputImage ?? top.composited(over: bottom)
    }

    /// Scale `image` to completely fill `targetSize`, then crop center.
    /// Final image extent is always (0,0,width,height) to match render buffers.
    private func resizedToFill(_ image: CIImage, targetSize: CGSize) -> CIImage {
        let extent = image.extent
        guard extent.width > 0, extent.height > 0 else {
            return image
        }

        let scale = max(
            targetSize.width  / extent.width,
            targetSize.height / extent.height
        )

        let scaled = image.transformed(by: CGAffineTransform(scaleX: scale, y: scale))

        // Crop a centered rect in scaled-image coordinates.
        let cropX = (scaled.extent.width  - targetSize.width)  / 2.0
        let cropY = (scaled.extent.height - targetSize.height) / 2.0
        let cropRect = CGRect(x: cropX, y: cropY, width: targetSize.width, height: targetSize.height)

        let cropped = scaled.cropped(to: cropRect)

        // Normalize extent so origin is (0,0). This is the important bit.
        return cropped.transformed(by: CGAffineTransform(
            translationX: -cropRect.origin.x,
            y: -cropRect.origin.y
        ))
    }
}
