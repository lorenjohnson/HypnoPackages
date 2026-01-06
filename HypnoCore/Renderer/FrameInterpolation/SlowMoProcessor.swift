//
//  SlowMoProcessor.swift
//  Hypnograph
//
//  ML-based slow-motion frame interpolation using VTFrameProcessor.
//  Uses Apple's frame rate conversion for smooth slow-mo during export.
//

import Foundation
import AVFoundation
import CoreVideo
import CoreImage
import VideoToolbox

// MARK: - Frame Interpolation Protocol

/// Protocol for frame interpolation implementations.
protocol FrameInterpolator {
    /// Interpolate between two frames.
    /// - Parameters:
    ///   - frame1: First frame (earlier in time)
    ///   - frame2: Second frame (later in time)
    ///   - blendFactor: 0.0 = frame1, 1.0 = frame2
    /// - Returns: Interpolated frame
    func interpolate(frame1: CIImage, frame2: CIImage, blendFactor: Float) -> CIImage
}

// MARK: - Simple Cross-Fade Interpolator (Fallback)

/// Simple cross-fade interpolation between frames.
/// Used as fallback when VTFrameProcessor is not available.
final class CrossFadeInterpolator: FrameInterpolator {

    func interpolate(frame1: CIImage, frame2: CIImage, blendFactor: Float) -> CIImage {
        let dissolve = CIFilter(name: "CIDissolveTransition")!
        dissolve.setValue(frame1, forKey: kCIInputImageKey)
        dissolve.setValue(frame2, forKey: kCIInputTargetImageKey)
        dissolve.setValue(blendFactor, forKey: kCIInputTimeKey)
        return dissolve.outputImage ?? frame1
    }
}

// MARK: - VTFrameProcessor-based Interpolator

/// ML-based frame interpolation using VTFrameProcessor.
/// Provides high-quality optical flow-based frame interpolation for slow-motion.
@available(macOS 15.4, *)
final class VTSlowMoProcessor {

    enum ProcessorError: Error {
        case configurationFailed
        case parametersFailed
        case processingFailed(Error)
        case bufferCreationFailed
    }

    private let processor = VTFrameProcessor()
    private var isSessionActive = false
    private let frameWidth: Int
    private let frameHeight: Int
    private let ciContext: CIContext

    init(width: Int, height: Int, ciContext: CIContext) {
        self.frameWidth = width
        self.frameHeight = height
        self.ciContext = ciContext
    }

    /// Start a frame rate conversion session.
    func startSession() throws {
        guard let configuration = VTFrameRateConversionConfiguration(
            frameWidth: frameWidth,
            frameHeight: frameHeight,
            usePrecomputedFlow: false,
            qualityPrioritization: .quality,
            revision: .revision1
        ) else {
            throw ProcessorError.configurationFailed
        }

        try processor.startSession(configuration: configuration)
        isSessionActive = true
    }

    /// End the current session.
    func endSession() {
        if isSessionActive {
            processor.endSession()
            isSessionActive = false
        }
    }

    /// Interpolate a single frame between two source frames.
    /// - Parameters:
    ///   - frame1: First source frame
    ///   - pts1: Presentation time of first frame
    ///   - frame2: Second source frame
    ///   - pts2: Presentation time of second frame
    ///   - blendFactor: Position between frames (0.0 = frame1, 1.0 = frame2)
    /// - Returns: Interpolated pixel buffer
    func interpolate(
        frame1: CVPixelBuffer,
        pts1: CMTime,
        frame2: CVPixelBuffer,
        pts2: CMTime,
        blendFactor: Float
    ) async throws -> CVPixelBuffer {

        if !isSessionActive {
            try startSession()
        }

        // Create frame wrappers
        guard let source = VTFrameProcessorFrame(buffer: frame1, presentationTimeStamp: pts1),
              let next = VTFrameProcessorFrame(buffer: frame2, presentationTimeStamp: pts2) else {
            throw ProcessorError.bufferCreationFailed
        }

        // Calculate interpolated timestamp
        let duration = CMTimeSubtract(pts2, pts1)
        let offset = CMTimeMultiplyByFloat64(duration, multiplier: Float64(blendFactor))
        let interpolatedPTS = CMTimeAdd(pts1, offset)

        // Create destination buffer
        let destBuffer = try createPixelBuffer()
        guard let destFrame = VTFrameProcessorFrame(buffer: destBuffer, presentationTimeStamp: interpolatedPTS) else {
            throw ProcessorError.bufferCreationFailed
        }

        // Create parameters
        guard let parameters = VTFrameRateConversionParameters(
            sourceFrame: source,
            nextFrame: next,
            opticalFlow: nil,
            interpolationPhase: [blendFactor],
            submissionMode: .sequential,
            destinationFrames: [destFrame]
        ) else {
            throw ProcessorError.parametersFailed
        }

        // Process
        do {
            try await processor.process(parameters: parameters)
        } catch {
            throw ProcessorError.processingFailed(error)
        }

        return destBuffer
    }

    private func createPixelBuffer() throws -> CVPixelBuffer {
        var pixelBuffer: CVPixelBuffer?
        let status = CVPixelBufferCreate(
            kCFAllocatorDefault,
            frameWidth,
            frameHeight,
            kCVPixelFormatType_32BGRA,
            [kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary] as CFDictionary,
            &pixelBuffer
        )

        guard status == kCVReturnSuccess, let buffer = pixelBuffer else {
            throw ProcessorError.bufferCreationFailed
        }
        return buffer
    }

    deinit {
        endSession()
    }
}

// MARK: - Slow-Mo Capability Check

/// Utility to check if ML-based slow-mo is available.
enum SlowMoCapability {
    case vtFrameProcessor   // VTFrameProcessor available (macOS 15.4+)
    case fallbackOnly       // Only cross-fade available

    static var current: SlowMoCapability {
        if #available(macOS 15.4, *) {
            return .vtFrameProcessor
        }
        return .fallbackOnly
    }
}

