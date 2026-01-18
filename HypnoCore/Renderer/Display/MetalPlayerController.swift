//
//  MetalPlayerController.swift
//  HypnoCore
//
//  Controller that bridges AVPlayer-based compositions with MetalPlayerView display.
//  This is the integration layer for Direction A of the Metal playback pipeline.
//

import AVFoundation
import AppKit
import CoreMedia
import Combine

/// Controller that manages frame pulling from AVPlayer and display via MetalPlayerView.
/// This replaces the direct AVPlayerView approach with Metal rendering.
@MainActor
public final class MetalPlayerController: ObservableObject {

    // MARK: - Public Properties

    /// The Metal view for display
    public let view: MetalPlayerView

    /// Whether playback is currently active
    @Published public private(set) var isPlaying: Bool = false

    /// Current playback time
    @Published public private(set) var currentTime: CMTime = .zero

    // MARK: - Audio

    /// Volume level (0.0 to 1.0)
    public var volume: Float {
        get { frameSource?.volume ?? 0 }
        set { frameSource?.volume = newValue }
    }

    /// Whether audio is muted
    public var isMuted: Bool {
        get { frameSource?.isMuted ?? false }
        set { frameSource?.isMuted = newValue }
    }

    /// Audio output device UID (nil = system default)
    public var audioOutputDeviceUniqueID: String? {
        get { frameSource?.audioOutputDeviceUniqueID }
        set { frameSource?.audioOutputDeviceUniqueID = newValue }
    }

    // MARK: - Private Properties

    private var frameSource: AVPlayerFrameSource?
    private let textureCache = TextureCache()
    private var displayLink: CVDisplayLink?
    private var timeObserverToken: Any?
    private var endObserverToken: Any?

    // Playback configuration
    private var playRate: Float = 1.0
    private var shouldLoop: Bool = true

    // MARK: - Initialization

    public init() {
        self.view = MetalPlayerView(frame: .zero, device: SharedRenderer.metalDevice)
        view.contentMode = .aspectFit
    }

    deinit {
        // Stop display link directly (it's thread-safe)
        if let link = displayLink {
            CVDisplayLinkStop(link)
        }
    }

    // MARK: - Public API

    /// Load a player item for display
    public func load(playerItem: AVPlayerItem) {
        // Create or reuse frame source
        let player: AVPlayer
        if let existingSource = frameSource {
            player = existingSource.player
            player.replaceCurrentItem(with: playerItem)
            existingSource.attachOutput(to: playerItem)
        } else {
            player = AVPlayer(playerItem: playerItem)
            let source = AVPlayerFrameSource(player: player)
            source.attachOutput(to: playerItem)
            frameSource = source
        }

        // Setup observers
        setupObservers(player: player, item: playerItem)

        // Start display link if playing
        if isPlaying {
            startDisplayLink()
        }
    }

    /// Start playback
    public func play(rate: Float = 1.0) {
        guard let source = frameSource else { return }

        playRate = rate
        source.player.playImmediately(atRate: rate)
        isPlaying = true
        startDisplayLink()
    }

    /// Pause playback
    public func pause() {
        frameSource?.player.pause()
        isPlaying = false
        // Keep display link running to show frozen frame
    }

    /// Stop playback and release resources
    public func stop() {
        stopDisplayLink()

        // Remove observers
        if let token = timeObserverToken, let player = frameSource?.player {
            player.removeTimeObserver(token)
            timeObserverToken = nil
        }
        if let token = endObserverToken {
            NotificationCenter.default.removeObserver(token)
            endObserverToken = nil
        }

        frameSource?.player.replaceCurrentItem(with: nil)
        isPlaying = false
        currentTime = .zero
    }

    /// Seek to a specific time
    public func seek(to time: CMTime, completion: ((Bool) -> Void)? = nil) {
        frameSource?.player.seek(to: time, toleranceBefore: .zero, toleranceAfter: .zero) { finished in
            completion?(finished)
        }
    }

    /// Set content display mode
    public func setContentMode(_ mode: MetalPlayerView.ContentMode) {
        view.contentMode = mode
    }

    /// Configure looping behavior
    public func setLooping(_ enabled: Bool) {
        shouldLoop = enabled
    }

    // MARK: - Display Link

    private func startDisplayLink() {
        guard displayLink == nil else { return }

        var link: CVDisplayLink?
        CVDisplayLinkCreateWithActiveCGDisplays(&link)
        guard let displayLink = link else { return }

        let callback: CVDisplayLinkOutputCallback = { displayLink, inNow, inOutputTime, flagsIn, flagsOut, displayLinkContext in
            guard let context = displayLinkContext else { return kCVReturnSuccess }
            let controller = Unmanaged<MetalPlayerController>.fromOpaque(context).takeUnretainedValue()
            controller.displayLinkFired()
            return kCVReturnSuccess
        }

        CVDisplayLinkSetOutputCallback(displayLink, callback, Unmanaged.passUnretained(self).toOpaque())
        CVDisplayLinkStart(displayLink)
        self.displayLink = displayLink
    }

    private func stopDisplayLink() {
        guard let link = displayLink else { return }
        CVDisplayLinkStop(link)
        displayLink = nil
    }

    private func displayLinkFired() {
        // Called on display link thread - need to dispatch to main for UI updates
        guard let source = frameSource else { return }

        let time = source.currentTime
        guard let frame = source.bestFrame(for: time) else { return }

        // Convert to texture
        let texture: MTLTexture?
        if frame.isYUV {
            // For YUV, we need to convert - this is handled by MetalPlayerView
            // For now, use the texture cache directly
            if let yuvTextures = textureCache.yuvTextures(from: frame.pixelBuffer) {
                // MetalPlayerView needs to handle YUV directly
                // For initial implementation, fall back to BGRA
                texture = textureCache.texture(from: frame.pixelBuffer)
            } else {
                texture = nil
            }
        } else {
            texture = textureCache.texture(from: frame.pixelBuffer)
        }

        // Update view on main thread
        DispatchQueue.main.async { [weak self] in
            self?.view.setTexture(texture)
        }
    }

    // MARK: - Observers

    private func setupObservers(player: AVPlayer, item: AVPlayerItem) {
        // Remove existing observers
        if let token = timeObserverToken {
            player.removeTimeObserver(token)
        }
        if let token = endObserverToken {
            NotificationCenter.default.removeObserver(token)
        }

        // Time observer
        let interval = CMTime(seconds: 0.1, preferredTimescale: 600)
        timeObserverToken = player.addPeriodicTimeObserver(
            forInterval: interval,
            queue: .main
        ) { [weak self] time in
            self?.currentTime = time
        }

        // End observer for looping
        endObserverToken = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime,
            object: item,
            queue: .main
        ) { [weak self, weak player] _ in
            guard let self = self, let player = player, self.shouldLoop else { return }
            player.seek(to: .zero)
            if self.isPlaying {
                player.playImmediately(atRate: self.playRate)
            }
        }
    }
}

// MARK: - SwiftUI Wrapper

import SwiftUI

/// SwiftUI wrapper for MetalPlayerController
public struct MetalPlayerViewRepresentable: NSViewRepresentable {
    @ObservedObject var controller: MetalPlayerController

    public init(controller: MetalPlayerController) {
        self.controller = controller
    }

    public func makeNSView(context: Context) -> MetalPlayerView {
        controller.view
    }

    public func updateNSView(_ nsView: MetalPlayerView, context: Context) {
        // View updates handled by controller
    }
}
