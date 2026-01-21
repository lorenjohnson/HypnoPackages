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
    /// If a `FramingBias` is provided, the crop translation is biased toward the focus anchor
    /// while keeping edges opaque (no blank edges).
    static func aspectFill(image: CIImage, to size: CGSize, bias: FramingBias? = nil) -> CIImage {
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

        if let bias {
            // Convert target from NDC to output pixel coordinates.
            let targetX = ((bias.targetNDC.x + 1) * 0.5) * size.width
            let targetY = ((bias.targetNDC.y + 1) * 0.5) * size.height

            // Focus anchor in scaled image pixel coordinates.
            let anchor = CGPoint(
                x: max(0, min(1, bias.anchorNormalized.x)) * scaledSize.width,
                y: max(0, min(1, bias.anchorNormalized.y)) * scaledSize.height
            )

            // Desired translation so the anchor lands at the target.
            let desiredX = targetX - anchor.x
            let desiredY = targetY - anchor.y

            switch bias.axisPolicy {
            case .verticalOnly:
                if slackY > 0 {
                    y = max(-slackY, min(0, desiredY))
                }
            case .horizontalOnly:
                if slackX > 0 {
                    x = max(-slackX, min(0, desiredX))
                }
            case .both:
                if slackX > 0 {
                    x = max(-slackX, min(0, desiredX))
                }
                if slackY > 0 {
                    y = max(-slackY, min(0, desiredY))
                }
            }
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
        bias: FramingBias? = nil
    ) -> CIImage {
        switch framing {
        case .fill:
            return aspectFill(image: image, to: size, bias: bias)
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
