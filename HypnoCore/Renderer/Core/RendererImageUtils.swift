//
//  RendererImageUtils.swift
//  HypnoRenderer
//
//  Internal image processing helpers for renderer-only paths.
//

import CoreImage

enum RendererImageUtils {

    /// Convert AVFoundation's preferredTransform to work correctly with CIImage.
    static func convertTransformForCIImage(_ transform: CGAffineTransform, naturalSize: CGSize) -> CGAffineTransform {
        if transform.isIdentity {
            return transform
        }

        return CGAffineTransform(
            a: transform.a,
            b: -transform.b,
            c: -transform.c,
            d: transform.d,
            tx: transform.tx,
            ty: -transform.ty
        )
    }

    /// Scale and crop an image to fill the target size while maintaining aspect ratio.
    static func aspectFill(image: CIImage, to size: CGSize) -> CIImage {
        var img = image
        if img.extent.origin != .zero {
            img = img.transformed(by: CGAffineTransform(
                translationX: -img.extent.origin.x,
                y: -img.extent.origin.y
            ))
        }

        let imageSize = img.extent.size
        guard imageSize.width > 0, imageSize.height > 0, size.width > 0, size.height > 0 else {
            return img
        }

        let scale = max(size.width / imageSize.width, size.height / imageSize.height)

        let scaledImage = img.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        let scaledSize = scaledImage.extent.size

        let x = (size.width - scaledSize.width) / 2
        let y = (size.height - scaledSize.height) / 2

        let translated = scaledImage.transformed(by: CGAffineTransform(translationX: x, y: y))

        return translated.cropped(to: CGRect(origin: .zero, size: size))
    }

    /// Blend a foreground layer over a background using a Core Image blend filter.
    static func blend(
        layer: CIImage,
        over base: CIImage,
        mode: String,
        opacity: CGFloat = 1.0
    ) -> CIImage {
        let filter = CIFilter(name: mode)
        filter?.setValue(layer, forKey: kCIInputImageKey)
        filter?.setValue(base, forKey: kCIInputBackgroundImageKey)

        guard let blended = filter?.outputImage else { return layer }

        guard opacity < 1.0 else { return blended }

        return applyOpacity(blended, over: base, opacity: opacity)
    }

    private static func applyOpacity(
        _ foreground: CIImage,
        over background: CIImage,
        opacity: CGFloat
    ) -> CIImage {
        guard let opacityFilter = CIFilter(name: "CIColorMatrix") else {
            return foreground
        }

        let alphaVector = CIVector(x: 0, y: 0, z: 0, w: opacity)
        opacityFilter.setValue(foreground, forKey: kCIInputImageKey)
        opacityFilter.setValue(alphaVector, forKey: "inputAVector")

        guard let transparentForeground = opacityFilter.outputImage else {
            return foreground
        }

        guard let composite = CIFilter(name: "CISourceOverCompositing") else {
            return foreground
        }
        composite.setValue(transparentForeground, forKey: kCIInputImageKey)
        composite.setValue(background, forKey: kCIInputBackgroundImageKey)

        return composite.outputImage ?? foreground
    }
}
