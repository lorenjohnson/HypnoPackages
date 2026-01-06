//
//  CompressionMetalEffect.swift
//  Hypnograph
//
//  Real compression artifacts.
//  Supports JPEG, JPEG2000, and color reduction.
//

import Foundation
import CoreImage
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

/// Compression format options
enum CompressionFormat: Int {
    case jpeg = 0       // Classic blocky artifacts
    case jpeg2000 = 1   // Wavelet artifacts (blurry/wavy)
    case posterize = 2  // Color reduction (like GIF)
}

/// Real compression effect with multiple format options
final class CompressionMetalEffect: Effect {

    // MARK: - Parameter Specs

    static var parameterSpecs: [String: ParameterSpec] {
        [
            "quality": .float(default: 0.05, range: 0.001...1.0),
            "passes": .int(default: 3, range: 1...20),
            "format": .int(default: 0, range: 0...2),  // 0=jpeg, 1=jpeg2000, 2=posterize
            "colorLevels": .int(default: 4, range: 2...32)  // For posterize mode
        ]
    }

    // MARK: - Properties

    var name: String { "Compression" }
    var requiredLookback: Int { 0 }

    var quality: Float
    var passes: Int
    var format: CompressionFormat
    var colorLevels: Int  // For posterize mode

    private let ciContext = CIContext(options: [.useSoftwareRenderer: false])

    // MARK: - Init

    init(quality: Float, passes: Int, format: Int, colorLevels: Int) {
        self.quality = max(0.001, min(1.0, quality))
        self.passes = max(1, min(20, passes))
        self.format = CompressionFormat(rawValue: format) ?? .jpeg
        self.colorLevels = max(2, min(32, colorLevels))
    }

    convenience init?(params: [String: AnyCodableValue]?) {
        let p = Params(params, specs: Self.parameterSpecs)
        self.init(quality: p.float("quality"), passes: p.int("passes"), format: p.int("format"), colorLevels: p.int("colorLevels"))
    }

    // MARK: - Effect Protocol

    func apply(to image: CIImage, context: inout RenderContext) -> CIImage {
        let extent = image.extent
        guard extent.width > 0, extent.height > 0 else { return image }

        var currentCI = image

        // Multiple compression passes
        for _ in 0..<passes {
            switch format {
            case .jpeg, .jpeg2000:
                guard let cgImage = ciContext.createCGImage(currentCI, from: extent),
                      let compressed = compressImage(cgImage) else {
                    break
                }
                currentCI = CIImage(cgImage: compressed)

            case .posterize:
                currentCI = posterizeImage(currentCI)
            }
        }

        return currentCI
    }

    private func compressImage(_ cgImage: CGImage) -> CGImage? {
        let typeIdentifier: String
        switch format {
        case .jpeg:
            typeIdentifier = UTType.jpeg.identifier
        case .jpeg2000:
            typeIdentifier = "public.jpeg-2000"
        case .posterize:
            return cgImage  // Handled separately
        }

        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            data as CFMutableData,
            typeIdentifier as CFString,
            1, nil
        ) else { return nil }

        let options: [CFString: Any] = [
            kCGImageDestinationLossyCompressionQuality: quality
        ]
        CGImageDestinationAddImage(destination, cgImage, options as CFDictionary)

        guard CGImageDestinationFinalize(destination),
              let source = CGImageSourceCreateWithData(data as CFData, nil) else {
            return nil
        }
        return CGImageSourceCreateImageAtIndex(source, 0, nil)
    }

    private func posterizeImage(_ image: CIImage) -> CIImage {
        // Use CIColorPosterize for indexed color reduction
        guard let filter = CIFilter(name: "CIColorPosterize") else {
            return image
        }
        filter.setValue(image, forKey: kCIInputImageKey)
        filter.setValue(NSNumber(value: colorLevels), forKey: "inputLevels")
        return filter.outputImage ?? image
    }

    func reset() {
        // Nothing to reset
    }

    func copy() -> Effect {
        CompressionMetalEffect(quality: quality, passes: passes,
                             format: format.rawValue, colorLevels: colorLevels)
    }
}

