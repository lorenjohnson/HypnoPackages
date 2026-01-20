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
        let clip = VideoClip(file: file, startTime: .zero, duration: duration)
        let source = HypnogramSource(clip: clip)
        let hypnoClip = HypnogramClip(sources: [source], targetDuration: duration)

        let engine = RenderEngine()
        let config = RenderEngine.Config(outputSize: CGSize(width: 320, height: 180), frameRate: 30, enableEffects: true)
        let result = await engine.makePlayerItem(
            clip: hypnoClip,
            config: config,
            effectManager: nil
        )

        switch result {
        case .success:
            #expect(true)
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
        let clip = VideoClip(file: file, startTime: .zero, duration: duration)
        let source = HypnogramSource(clip: clip)
        let hypnoClip = HypnogramClip(sources: [source], targetDuration: duration)

        let outputURL = tempDir.appendingPathComponent("export-output.png")
        let config = RenderEngine.Config(outputSize: CGSize(width: 128, height: 72), frameRate: 30, enableEffects: true)

        let engine = RenderEngine()
        let result = await engine.export(
            clip: hypnoClip,
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
        let clip = VideoClip(file: file, startTime: .zero, duration: duration)
        let source = HypnogramSource(clip: clip)
        let hypnoClip = HypnogramClip(sources: [source], targetDuration: duration)

        let outputURL = tempDir.appendingPathComponent("export-output.mov")
        let config = RenderEngine.Config(outputSize: CGSize(width: 128, height: 72), frameRate: frameRate, enableEffects: true)

        let engine = RenderEngine()
        let result = await engine.export(
            clip: hypnoClip,
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
