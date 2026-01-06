//
//  MediaLibraryTests.swift
//  HypnoCoreTests
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

struct MediaLibraryTests {

    @Test func mediaLibraryRandomClipForImage() async throws {
        let tempDir = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let stores = try makeStores(in: tempDir.appendingPathComponent("core", isDirectory: true))
        let imageURL = tempDir.appendingPathComponent("library-image.png")
        try writeTestImage(to: imageURL, size: CGSize(width: 10, height: 10))

        let library = MediaLibrary(
            sources: [tempDir.path],
            allowedMediaTypes: [.images],
            exclusionStore: stores.exclusion,
            deleteStore: stores.delete
        )
        guard let clip = library.randomClip(clipLength: 1.25) else {
            #expect(Bool(false), "Expected image clip from library")
            return
        }

        #expect(clip.file.mediaKind == .image)
        #expect(abs(clip.duration.seconds - 1.25) < 0.01)
    }

    @Test func mediaLibraryRandomClipForVideo() async throws {
        let tempDir = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let stores = try makeStores(in: tempDir.appendingPathComponent("core", isDirectory: true))
        let videoURL = tempDir.appendingPathComponent("library-video.mov")
        try await writeTestVideo(to: videoURL, size: CGSize(width: 12, height: 12), frameCount: 4, frameRate: 30)

        let library = MediaLibrary(
            sources: [tempDir.path],
            allowedMediaTypes: [.videos],
            exclusionStore: stores.exclusion,
            deleteStore: stores.delete
        )
        guard let clip = library.randomClip(clipLength: 0.5) else {
            #expect(Bool(false), "Expected video clip from library")
            return
        }

        #expect(clip.file.mediaKind == .video)
        #expect(clip.duration.seconds <= 0.5 + 0.01)
        #expect(clip.startTime.seconds >= 0)
    }

    private func makeTempDirectory() throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(
            "hypnograph-tests-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func makeStores(in directory: URL) throws -> (exclusion: ExclusionStore, delete: DeleteStore) {
        let fm = FileManager.default
        if !fm.fileExists(atPath: directory.path) {
            try fm.createDirectory(at: directory, withIntermediateDirectories: true)
        }

        let exclusionURL = directory.appendingPathComponent("exclusions.json")
        let deleteURL = directory.appendingPathComponent("deletions.json")

        return (
            exclusion: ExclusionStore(url: exclusionURL),
            delete: DeleteStore(url: deleteURL)
        )
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
