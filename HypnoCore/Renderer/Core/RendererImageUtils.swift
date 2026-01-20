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
    /// If `personBoundsNormalized` is provided (normalized 0...1, origin bottom-left),
    /// the crop is vertically biased toward the top of that bounds (head) while keeping edges opaque.
    static func aspectFill(image: CIImage, to size: CGSize, personBoundsNormalized: CGRect? = nil) -> CIImage {
        var img = normalizeOrigin(image)
        let imageSize = img.extent.size
        guard imageSize.width > 0, imageSize.height > 0, size.width > 0, size.height > 0 else {
            return img
        }

        let scale = max(size.width / imageSize.width, size.height / imageSize.height)

        let scaledImage = img.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        let scaledSize = scaledImage.extent.size

        let slackX = scaledSize.width - size.width
        let slackY = scaledSize.height - size.height

        // Default: centered crop.
        var x = -slackX / 2
        var y = -slackY / 2

        // Bias vertically toward the detected person (typically portrait -> landscape crops).
        if let b = personBoundsNormalized, slackY > 0 {
            // Anchor on the top of the bounds (approx head).
            let headroomY = max(0, min(1, b.maxY + (b.height * 0.06)))
            let focusY = max(0, min(1, headroomY))
            // Place the head near the upper portion of the frame (avoid pushing it into the lower half).
            let targetY: CGFloat = 0.95
            let desiredY = (targetY * size.height) - (focusY * scaledSize.height)
            // Clamp so we never reveal empty edges.
            y = max(-slackY, min(0, desiredY))
        }

        let translated = scaledImage.transformed(by: CGAffineTransform(translationX: x, y: y))

        return translated.cropped(to: CGRect(origin: .zero, size: size))
    }

    /// Scale an image to fit inside the target size while maintaining aspect ratio.
    /// Empty/unused area is transparent so lower layers show through.
    static func aspectFit(image: CIImage, to size: CGSize) -> CIImage {
        var img = normalizeOrigin(image)

        let imageSize = img.extent.size
        guard imageSize.width > 0, imageSize.height > 0, size.width > 0, size.height > 0 else {
            return img
        }

        let scale = min(size.width / imageSize.width, size.height / imageSize.height)

        let scaledImage = img.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        let scaledSize = scaledImage.extent.size

        let x = (size.width - scaledSize.width) / 2
        let y = (size.height - scaledSize.height) / 2

        let translated = scaledImage.transformed(by: CGAffineTransform(translationX: x, y: y))

        let clearBackground = CIImage(color: .clear).cropped(to: CGRect(origin: .zero, size: size))
        let composited = translated.composited(over: clearBackground)

        return composited.cropped(to: CGRect(origin: .zero, size: size))
    }

    static func applySourceFraming(
        image: CIImage,
        to size: CGSize,
        framing: SourceFraming,
        personBoundsNormalized: CGRect? = nil
    ) -> CIImage {
        switch framing {
        case .fill:
            return aspectFill(image: image, to: size, personBoundsNormalized: personBoundsNormalized)
        case .fit:
            return aspectFit(image: image, to: size)
        }
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

    private static func normalizeOrigin(_ image: CIImage) -> CIImage {
        guard image.extent.origin != .zero else { return image }
        return image.transformed(by: CGAffineTransform(
            translationX: -image.extent.origin.x,
            y: -image.extent.origin.y
        ))
    }
}
