//
//  HypnoCoreHooks.swift
//  HypnoCore
//
//  Hooks for apps to provide external media resolution and export handling.
//  This allows HypnoCore to remain agnostic about specific external sources
//  (like Apple Photos) while apps can wire up the appropriate integrations.
//

import Foundation
import AVFoundation
import CoreImage

/// Hooks that apps can set to provide external media resolution and export handling.
/// HypnoCore calls these hooks when it needs to resolve external sources or notify about exports.
public struct HypnoCoreHooks {

    /// Shared instance - apps should configure this at startup
    public static var shared = HypnoCoreHooks()

    // MARK: - External Source Resolution

    /// Resolve an external video source identifier to an AVAsset.
    /// Apps should set this to handle their external sources (e.g., Apple Photos).
    /// The identifier is opaque to HypnoCore - apps can encode routing info as needed.
    public var resolveExternalVideo: ((String) async -> AVAsset?)?

    /// Resolve an external image source identifier to a CIImage.
    /// Apps should set this to handle their external sources (e.g., Apple Photos).
    /// The identifier is opaque to HypnoCore - apps can encode routing info as needed.
    public var resolveExternalImage: ((String) async -> CIImage?)?

    // MARK: - Export Callbacks

    /// Called when a video export completes successfully.
    /// Apps can use this to save to external destinations (e.g., Apple Photos).
    public var onVideoExportCompleted: ((URL) async -> Void)?

    /// Called when an image export completes successfully.
    /// Apps can use this to save to external destinations (e.g., Apple Photos).
    public var onImageExportCompleted: ((URL) async -> Void)?

    // MARK: - Init

    public init() {}
}
