//
//  HueWobbleEffect.swift
//  Hypnograph
//
//  Created by Loren Johnson on 20.11.25.
//

import CoreImage
import CoreMedia

/// Wobbles the hue over time with a sinusoidal oscillation.
struct HueWobbleEffect: Effect {
    var name: String { "Hue Wobble" }

    init() {}

    init?(params: [String: AnyCodableValue]?) {
        self.init()
    }

    func apply(to image: CIImage, context: inout RenderContext) -> CIImage {
        let t = CMTimeGetSeconds(context.time)
        let phase = Float(sin(t * 0.5))          // slow-ish oscillation
        let angle = phase * .pi                  // radians

        guard let filter = CIFilter(name: "CIHueAdjust") else {
            return image
        }

        filter.setValue(image, forKey: kCIInputImageKey)
        filter.setValue(angle, forKey: kCIInputAngleKey)

        return filter.outputImage ?? image
    }
}

