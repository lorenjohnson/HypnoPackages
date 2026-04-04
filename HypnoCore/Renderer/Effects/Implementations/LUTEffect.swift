//
//  LUTEffect.swift
//  Hypnograph
//
//  Apply a 3D LUT (Look Up Table) from a .cube file using CIColorCube filter.
//  LUT files can live in ~/Library/Application Support/<app>/luts/
//  or be bundled with HypnoCore defaults under BundledLUTs/
//

import CoreImage
import CoreMedia
import Foundation

/// Applies a 3D color LUT from a .cube file
final class LUTEffect: Effect {

    // MARK: - Parameter Specs (source of truth)

    static var parameterSpecs: [String: ParameterSpec] {
        [
            "lutFile": .file(fileExtension: "cube", directoryProvider: { HypnoCoreConfig.shared.lutsDirectory }),
            "intensity": .float(default: 1.0, range: 0...1)
        ]
    }

    // MARK: - Properties

    /// Blend intensity (0 = original, 1 = full LUT)
    let intensity: Float

    /// Name of the .cube file (without extension)
    let lutFileName: String

    /// Cached LUT data
    private var lutData: Data?
    private var lutSize: Int = 0
    private var lutLoaded = false

    /// Custom display name
    private var customName: String?

    var name: String {
        customName ?? "LUT - \(lutFileName)"
    }

    // MARK: - Init

    init(lutFile: String = "", intensity: Float = 1.0, name: String? = nil) {
        self.lutFileName = lutFile
        self.intensity = max(0, min(1, intensity))
        self.customName = name
        loadLUT()
    }

    required convenience init?(params: [String: AnyCodableValue]?) {
        let lutFile = params?["lutFile"]?.stringValue ?? ""
        let intensity = params?["intensity"]?.floatValue ?? 1.0
        let name = params?["name"]?.stringValue
        self.init(lutFile: lutFile, intensity: intensity, name: name)
    }

    // MARK: - LUT Loading

    private func loadLUT() {
        guard !lutFileName.isEmpty else {
            print("⚠️ LUTEffect: No LUT file specified")
            return
        }

        guard let lutURL = resolveLUTURL(named: lutFileName) else {
            print("⚠️ LUTEffect: LUT file not found for \(lutFileName)")
            return
        }

        do {
            let content = try String(contentsOf: lutURL, encoding: .utf8)
            parseCubeFile(content)
        } catch {
            print("⚠️ LUTEffect: Failed to read LUT file: \(error)")
        }
    }

    private func resolveLUTURL(named lutFileName: String) -> URL? {
        let fm = FileManager.default
        let relativePath = lutFileName.hasSuffix(".cube") ? lutFileName : "\(lutFileName).cube"

        let userURL = HypnoCoreConfig.shared.lutsDirectory.appendingPathComponent(relativePath)
        if fm.fileExists(atPath: userURL.path) {
            return userURL
        }

        guard let bundledRoot = HypnoCoreBundle.bundle.resourceURL?.appendingPathComponent("BundledLUTs", isDirectory: true) else {
            return nil
        }

        let bundledURL = bundledRoot.appendingPathComponent(relativePath)
        if fm.fileExists(atPath: bundledURL.path) {
            return bundledURL
        }

        return nil
    }

    private func parseCubeFile(_ content: String) {
        var size = 0
        var rgbValues: [Float] = []

        let lines = content.components(separatedBy: .newlines)

        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            // Skip comments and empty lines
            if trimmed.isEmpty || trimmed.hasPrefix("#") {
                continue
            }

            // Parse LUT size
            if trimmed.uppercased().hasPrefix("LUT_3D_SIZE") {
                let parts = trimmed.components(separatedBy: .whitespaces)
                if parts.count >= 2, let s = Int(parts.last ?? "") {
                    size = s
                }
                continue
            }

            // Skip other metadata (TITLE, DOMAIN_MIN, DOMAIN_MAX, etc.)
            if trimmed.contains("_") || trimmed.uppercased().hasPrefix("TITLE") {
                continue
            }

            // Parse RGB values
            let components = trimmed.components(separatedBy: .whitespaces)
                .filter { !$0.isEmpty }
                .compactMap { Float($0) }

            if components.count >= 3 {
                rgbValues.append(contentsOf: [components[0], components[1], components[2], 1.0])
            }
        }

        guard size > 0 else {
            print("⚠️ LUTEffect: Invalid LUT size")
            return
        }

        let expectedCount = size * size * size * 4
        guard rgbValues.count == expectedCount else {
            print("⚠️ LUTEffect: Expected \(expectedCount) values, got \(rgbValues.count)")
            return
        }

        // Convert to Data for CIColorCube
        lutData = Data(bytes: rgbValues, count: rgbValues.count * MemoryLayout<Float>.size)
        lutSize = size
        lutLoaded = true
        print("✓ LUTEffect: Loaded \(lutFileName) (\(size)x\(size)x\(size))")
    }

    // MARK: - Effect

    func apply(to image: CIImage, context: inout RenderContext) -> CIImage {
        guard lutLoaded, let lutData = lutData else {
            return image
        }

        guard let filter = CIFilter(name: "CIColorCubeWithColorSpace") else {
            return image
        }

        filter.setValue(image, forKey: kCIInputImageKey)
        filter.setValue(lutSize, forKey: "inputCubeDimension")
        filter.setValue(lutData, forKey: "inputCubeData")
        filter.setValue(CGColorSpaceCreateDeviceRGB(), forKey: "inputColorSpace")

        guard let lutOutput = filter.outputImage else {
            return image
        }

        // Blend with original based on intensity
        if intensity < 1.0 {
            guard let blend = CIFilter(name: "CIColorMatrix") else {
                return lutOutput
            }
            // Use dissolve blend
            let alpha = CGFloat(intensity)
            blend.setValue(lutOutput, forKey: kCIInputImageKey)
            blend.setValue(CIVector(x: alpha, y: 0, z: 0, w: 0), forKey: "inputRVector")
            blend.setValue(CIVector(x: 0, y: alpha, z: 0, w: 0), forKey: "inputGVector")
            blend.setValue(CIVector(x: 0, y: 0, z: alpha, w: 0), forKey: "inputBVector")
            blend.setValue(CIVector(x: 0, y: 0, z: 0, w: 1), forKey: "inputAVector")
            blend.setValue(CIVector(x: 0, y: 0, z: 0, w: 0), forKey: "inputBiasVector")

            // Get scaled LUT result
            guard let scaledLUT = blend.outputImage else {
                return lutOutput
            }

            // Scale original by (1 - intensity)
            guard let origBlend = CIFilter(name: "CIColorMatrix") else {
                return lutOutput
            }
            let origAlpha = CGFloat(1.0 - intensity)
            origBlend.setValue(image, forKey: kCIInputImageKey)
            origBlend.setValue(CIVector(x: origAlpha, y: 0, z: 0, w: 0), forKey: "inputRVector")
            origBlend.setValue(CIVector(x: 0, y: origAlpha, z: 0, w: 0), forKey: "inputGVector")
            origBlend.setValue(CIVector(x: 0, y: 0, z: origAlpha, w: 0), forKey: "inputBVector")
            origBlend.setValue(CIVector(x: 0, y: 0, z: 0, w: 1), forKey: "inputAVector")
            origBlend.setValue(CIVector(x: 0, y: 0, z: 0, w: 0), forKey: "inputBiasVector")

            guard let scaledOrig = origBlend.outputImage else {
                return lutOutput
            }

            // Add them together
            guard let add = CIFilter(name: "CIAdditionCompositing") else {
                return lutOutput
            }
            add.setValue(scaledLUT, forKey: kCIInputImageKey)
            add.setValue(scaledOrig, forKey: kCIInputBackgroundImageKey)

            return add.outputImage ?? lutOutput
        }

        return lutOutput
    }

    func copy() -> Effect {
        LUTEffect(lutFile: lutFileName, intensity: intensity, name: customName)
    }
}
