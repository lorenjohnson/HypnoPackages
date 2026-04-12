//
//  RenderEngineTests.swift
//  HypnoRendererTests
//
//  Created by Loren Johnson on 15.11.25.
//

import Testing
import AVFoundation
import CoreMedia
import CoreImage
import CoreGraphics
import CoreVideo
import ImageIO
import UniformTypeIdentifiers
import HypnoCore

struct RenderEngineTests {

    @Test func renderEngineBuildsPlayerItemForStillImage() async throws {
        let tempDir = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let imageURL = tempDir.appendingPathComponent("still.png")
        try writeTestImage(to: imageURL, size: CGSize(width: 8, height: 8))

        let duration = CMTime(seconds: 2, preferredTimescale: 600)
        let file = MediaFile(source: .url(imageURL), mediaKind: .image, duration: duration)
        let mediaClip = MediaClip(file: file, startTime: .zero, duration: duration)
        let layer = Layer(mediaClip: mediaClip)
        let composition = Composition(layers: [layer], targetDuration: duration)

        let engine = RenderEngine()
        let config = RenderEngine.Config(outputSize: CGSize(width: 320, height: 180), frameRate: 30, enableEffects: true)
        let result = await engine.makePlayerItem(
            composition: composition,
            config: config,
            effectManager: nil
        )

        switch result {
        case .success:
            #expect(Bool(true))
        case .failure(let error):
            #expect(Bool(false), "Expected player item, got error: \(error)")
        }
    }

    @Test func renderEngineExportsStillMontageAsPNG() async throws {
        let tempDir = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let imageURL = tempDir.appendingPathComponent("export.png")
        try writeTestImage(to: imageURL, size: CGSize(width: 8, height: 8))

        let duration = CMTime(seconds: 1, preferredTimescale: 600)
        let file = MediaFile(source: .url(imageURL), mediaKind: .image, duration: duration)
        let mediaClip = MediaClip(file: file, startTime: .zero, duration: duration)
        let layer = Layer(mediaClip: mediaClip)
        let composition = Composition(layers: [layer], targetDuration: duration)

        let outputURL = tempDir.appendingPathComponent("export-output.png")
        let config = RenderEngine.Config(outputSize: CGSize(width: 128, height: 72), frameRate: 30, enableEffects: true)

        let engine = RenderEngine()
        let result = await engine.export(
            composition: composition,
            outputURL: outputURL,
            config: config
        )

        switch result {
        case .success(let url):
            #expect(url.path == outputURL.path)
            #expect(FileManager.default.fileExists(atPath: url.path))
        case .failure(let error):
            #expect(Bool(false), "Expected export success, got error: \(error)")
        }
    }

    @Test func renderEngineExportsVideo() async throws {
        let tempDir = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let videoURL = tempDir.appendingPathComponent("export-source.mov")
        let frameRate = 30
        let frameCount = 5
        try await writeTestVideo(to: videoURL, size: CGSize(width: 16, height: 16), frameCount: frameCount, frameRate: frameRate)

        let duration = CMTime(value: CMTimeValue(frameCount), timescale: CMTimeScale(frameRate))
        let file = MediaFile(source: .url(videoURL), mediaKind: .video, duration: duration)
        let mediaClip = MediaClip(file: file, startTime: .zero, duration: duration)
        let layer = Layer(mediaClip: mediaClip)
        let composition = Composition(layers: [layer], targetDuration: duration)

        let outputURL = tempDir.appendingPathComponent("export-output.mov")
        let config = RenderEngine.Config(outputSize: CGSize(width: 128, height: 72), frameRate: frameRate, enableEffects: true)

        let engine = RenderEngine()
        let result = await engine.export(
            composition: composition,
            outputURL: outputURL,
            config: config
        )

        switch result {
        case .success(let url):
            #expect(url.path == outputURL.path)
            #expect(FileManager.default.fileExists(atPath: url.path))
        case .failure(let error):
            #expect(Bool(false), "Expected export success, got error: \(error)")
        }
    }

    @Test func renderEngineExportsSequenceWithNoTransitions() async throws {
        let tempDir = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let hypnogram = try await makeSequenceHypnogram(
            in: tempDir,
            transitionStyle: .none,
            transitionDuration: 0
        )

        let outputURL = tempDir.appendingPathComponent("sequence-none.mov")
        let config = RenderEngine.Config(
            outputSize: CGSize(width: 128, height: 72),
            frameRate: 30,
            enableEffects: true
        )

        let engine = RenderEngine()
        let result = await engine.export(
            hypnogram: hypnogram,
            outputURL: outputURL,
            config: config
        )

        switch result {
        case .success(let url):
            #expect(url.path == outputURL.path)
            #expect(FileManager.default.fileExists(atPath: url.path))
        case .failure(let error):
            #expect(Bool(false), "Expected sequence export success with no transitions, got error: \(error)")
        }
    }

    @Test func renderEngineExportsSequenceWithNoTransitionsEvenWhenDurationIsSet() async throws {
        let tempDir = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let hypnogram = try await makeSequenceHypnogram(
            in: tempDir,
            transitionStyle: .none,
            transitionDuration: 2.0
        )

        let outputURL = tempDir.appendingPathComponent("sequence-none-duration-set.mov")
        let config = RenderEngine.Config(
            outputSize: CGSize(width: 128, height: 72),
            frameRate: 30,
            enableEffects: true
        )

        let engine = RenderEngine()
        let result = await engine.export(
            hypnogram: hypnogram,
            outputURL: outputURL,
            config: config
        )

        switch result {
        case .success(let url):
            #expect(url.path == outputURL.path)
            #expect(FileManager.default.fileExists(atPath: url.path))
        case .failure(let error):
            #expect(Bool(false), "Expected sequence export success with no transitions even when duration is set, got error: \(error)")
        }
    }

    @Test func renderEngineExportsSequenceWithDissolveTransitions() async throws {
        let tempDir = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let hypnogram = try await makeSequenceHypnogram(
            in: tempDir,
            transitionStyle: .crossfade,
            transitionDuration: 0.15
        )

        let outputURL = tempDir.appendingPathComponent("sequence-dissolve.mov")
        let config = RenderEngine.Config(
            outputSize: CGSize(width: 128, height: 72),
            frameRate: 30,
            enableEffects: true
        )

        let engine = RenderEngine()
        let result = await engine.export(
            hypnogram: hypnogram,
            outputURL: outputURL,
            config: config
        )

        switch result {
        case .success(let url):
            #expect(url.path == outputURL.path)
            #expect(FileManager.default.fileExists(atPath: url.path))
        case .failure(let error):
            #expect(Bool(false), "Expected sequence export success with dissolve transitions, got error: \(error)")
        }
    }

    @Test func renderEngineExportsNineCompositionSequenceShapeWithTopLevelNone() async throws {
        let tempDir = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let durations: [Double] = [
            16.476666666666667,
            20.916666666666668,
            21.488333333333333,
            18.276666666666667,
            16.661666666666665,
            2.598333333333333,
            19.203333333333333,
            10.208333333333334,
            7.573333333333333
        ]

        let hypnogram = try await makeSequenceHypnogram(
            in: tempDir,
            durations: durations,
            topLevelTransitionStyle: .none,
            topLevelTransitionDuration: 1.0,
            perCompositionTransitionStyle: nil,
            perCompositionTransitionDuration: nil
        )

        let outputURL = tempDir.appendingPathComponent("sequence-nine-top-level-none.mov")
        let config = RenderEngine.Config(
            outputSize: CGSize(width: 128, height: 72),
            frameRate: 30,
            enableEffects: true
        )

        let engine = RenderEngine()
        let result = await engine.export(
            hypnogram: hypnogram,
            outputURL: outputURL,
            config: config
        )

        switch result {
        case .success(let url):
            #expect(url.path == outputURL.path)
            #expect(FileManager.default.fileExists(atPath: url.path))
        case .failure(let error):
            #expect(Bool(false), "Expected nine-composition top-level-none sequence export success, got error: \(error)")
        }
    }

    @Test func renderEngineExportsNineCompositionFrameAlignedSequenceWithTopLevelNone() async throws {
        let tempDir = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let frameAlignedDurations: [Double] = [
            16.466666666666665,
            20.933333333333334,
            21.5,
            18.266666666666666,
            16.666666666666668,
            2.6,
            19.2,
            10.2,
            7.566666666666666
        ]

        let hypnogram = try await makeSequenceHypnogram(
            in: tempDir,
            durations: frameAlignedDurations,
            topLevelTransitionStyle: .none,
            topLevelTransitionDuration: 1.0,
            perCompositionTransitionStyle: nil,
            perCompositionTransitionDuration: nil
        )

        let outputURL = tempDir.appendingPathComponent("sequence-nine-frame-aligned-top-level-none.mov")
        let config = RenderEngine.Config(
            outputSize: CGSize(width: 128, height: 72),
            frameRate: 30,
            enableEffects: true
        )

        let engine = RenderEngine()
        let result = await engine.export(
            hypnogram: hypnogram,
            outputURL: outputURL,
            config: config
        )

        switch result {
        case .success(let url):
            #expect(url.path == outputURL.path)
            #expect(FileManager.default.fileExists(atPath: url.path))
        case .failure(let error):
            #expect(Bool(false), "Expected nine-composition frame-aligned top-level-none sequence export success, got error: \(error)")
        }
    }

    private func makeTempDirectory() throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(
            "hypnograph-tests-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func writeTestImage(to url: URL, size: CGSize) throws {
        let image = CIImage(color: CIColor(red: 1, green: 0, blue: 0, alpha: 1))
            .cropped(to: CGRect(origin: .zero, size: size))
        let context = CIContext()
        guard let cgImage = context.createCGImage(image, from: image.extent) else {
            throw TestImageError.failedToCreateCGImage
        }
        guard let destination = CGImageDestinationCreateWithURL(
            url as CFURL,
            UTType.png.identifier as CFString,
            1,
            nil
        ) else {
            throw TestImageError.failedToCreateDestination
        }
        CGImageDestinationAddImage(destination, cgImage, nil)
        guard CGImageDestinationFinalize(destination) else {
            throw TestImageError.failedToWriteImage
        }
    }

    private func writeTestVideo(
        to url: URL,
        size: CGSize,
        frameCount: Int,
        frameRate: Int
    ) async throws {
        try? FileManager.default.removeItem(at: url)

        let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        let settings: [String: Any] = [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: Int(size.width),
            AVVideoHeightKey: Int(size.height)
        ]

        let input = AVAssetWriterInput(mediaType: .video, outputSettings: settings)
        input.expectsMediaDataInRealTime = false

        let attributes: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: Int(size.width),
            kCVPixelBufferHeightKey as String: Int(size.height),
            kCVPixelBufferCGImageCompatibilityKey as String: true,
            kCVPixelBufferCGBitmapContextCompatibilityKey as String: true
        ]
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: attributes)

        guard writer.canAdd(input) else {
            throw TestVideoError.failedToAddInput
        }
        writer.add(input)

        writer.startWriting()
        writer.startSession(atSourceTime: .zero)

        let frameDuration = CMTime(value: 1, timescale: CMTimeScale(frameRate))
        let colorSpace = CGColorSpaceCreateDeviceRGB()

        for frameIndex in 0..<frameCount {
            while !input.isReadyForMoreMediaData {
                try await Task.sleep(nanoseconds: 1_000_000)
            }

            guard let pixelBuffer = makePixelBuffer(size: size, colorSpace: colorSpace, frameIndex: frameIndex) else {
                throw TestVideoError.failedToCreatePixelBuffer
            }

            let presentationTime = CMTimeMultiply(frameDuration, multiplier: Int32(frameIndex))
            adaptor.append(pixelBuffer, withPresentationTime: presentationTime)
        }

        input.markAsFinished()

        await withCheckedContinuation { continuation in
            writer.finishWriting {
                continuation.resume()
            }
        }
    }

    private func makePixelBuffer(size: CGSize, colorSpace: CGColorSpace, frameIndex: Int) -> CVPixelBuffer? {
        var buffer: CVPixelBuffer?
        let attrs: [String: Any] = [
            kCVPixelBufferCGImageCompatibilityKey as String: true,
            kCVPixelBufferCGBitmapContextCompatibilityKey as String: true
        ]

        let status = CVPixelBufferCreate(
            kCFAllocatorDefault,
            Int(size.width),
            Int(size.height),
            kCVPixelFormatType_32BGRA,
            attrs as CFDictionary,
            &buffer
        )

        guard status == kCVReturnSuccess, let pixelBuffer = buffer else {
            return nil
        }

        CVPixelBufferLockBaseAddress(pixelBuffer, [])
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, []) }

        guard let baseAddress = CVPixelBufferGetBaseAddress(pixelBuffer) else {
            return nil
        }

        let bytesPerRow = CVPixelBufferGetBytesPerRow(pixelBuffer)
        let context = CGContext(
            data: baseAddress,
            width: Int(size.width),
            height: Int(size.height),
            bitsPerComponent: 8,
            bytesPerRow: bytesPerRow,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
        )

        guard let ctx = context else { return nil }

        let hue = CGFloat((frameIndex % 8)) / 8.0
        ctx.setFillColor(CGColor(red: hue, green: 0.2, blue: 1.0 - hue, alpha: 1.0))
        ctx.fill(CGRect(origin: .zero, size: size))

        return pixelBuffer
    }

    private func makeSequenceHypnogram(
        in directory: URL,
        transitionStyle: TransitionRenderer.TransitionType,
        transitionDuration: Double
    ) async throws -> Hypnogram {
        try await makeSequenceHypnogram(
            in: directory,
            durations: [12.0 / 30.0, 13.0 / 30.0, 14.0 / 30.0],
            topLevelTransitionStyle: transitionStyle,
            topLevelTransitionDuration: transitionDuration,
            perCompositionTransitionStyle: transitionStyle,
            perCompositionTransitionDuration: transitionDuration
        )
    }

    private func makeSequenceHypnogram(
        in directory: URL,
        durations: [Double],
        topLevelTransitionStyle: TransitionRenderer.TransitionType,
        topLevelTransitionDuration: Double,
        perCompositionTransitionStyle: TransitionRenderer.TransitionType?,
        perCompositionTransitionDuration: Double?
    ) async throws -> Hypnogram {
        let frameRate = 30
        let size = CGSize(width: 16, height: 16)

        let urls = durations.enumerated().map { index, _ in
            directory.appendingPathComponent("sequence-\(index).mov")
        }

        for (index, url) in urls.enumerated() {
            let frameCount = max(1, Int((durations[index] * Double(frameRate)).rounded()))
            try await writeTestVideo(
                to: url,
                size: size,
                frameCount: frameCount,
                frameRate: frameRate
            )
        }

        let compositions: [Composition] = urls.enumerated().map { index, url in
            let duration = CMTime(seconds: durations[index], preferredTimescale: 600)
            let file = MediaFile(source: .url(url), mediaKind: .video, duration: duration)
            let mediaClip = MediaClip(file: file, startTime: .zero, duration: duration)
            let layer = Layer(mediaClip: mediaClip)
            var composition = Composition(layers: [layer], targetDuration: duration)
            composition.transitionStyle = perCompositionTransitionStyle
            composition.transitionDuration = perCompositionTransitionDuration
            return composition
        }

        return Hypnogram(
            compositions: compositions,
            transitionStyle: topLevelTransitionStyle,
            transitionDuration: topLevelTransitionDuration
        )
    }

    private enum TestImageError: Error {
        case failedToCreateCGImage
        case failedToCreateDestination
        case failedToWriteImage
    }

    private enum TestVideoError: Error {
        case failedToAddInput
        case failedToCreatePixelBuffer
    }
}
