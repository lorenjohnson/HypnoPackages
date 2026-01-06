//
//  DatamoshParams.swift
//  Hypnograph
//
//  Codec-style datamosh effect parameters.
//  Simulates I-frame freeze + P-frame drift in the decoded domain.
//

import Foundation
import simd

/// Parameters for the Metal datamosh compute shader.
/// Controls temporal history, block behavior, feedback, and burst timing.
struct DatamoshParams {

    // MARK: - Temporal History

    /// Minimum history offset to sample from (e.g., 5 = at least 5 frames back)
    var minHistoryOffset: Int

    /// Maximum history offset to sample from (e.g., 80 = up to 80 frames back)
    var maxHistoryOffset: Int

    /// If true, use frozenHistoryOffset instead of random sampling
    var freezeReference: Bool

    /// Specific offset to use when freezeReference is true
    var frozenHistoryOffset: Int?

    // MARK: - Block Behavior

    /// Size of blocks in pixels (8, 16, 32, etc.)
    var blockSize: Int

    /// Base probability (0-1) that a block participates in mosh (before motion weighting)
    var blockMoshProbability: Float

    /// How much motion/frame-difference increases mosh probability (0 = random only, 1 = fully motion-driven)
    var motionSensitivity: Float

    /// Probability (0-1) that a moshed block updates from current frame (vs. keeps history)
    var updateProbability: Float

    /// Mix between history (0) and current (1) for updated blocks
    var smearStrength: Float

    /// How much to jitter sampling coords in history (0-1)
    var jitterAmount: Float

    // MARK: - Feedback

    /// Blend amount with previous output (0-1)
    var feedbackAmount: Float

    // MARK: - Blockiness

    /// Pixelation amount (0 = fluid/smooth, 1 = very blocky/Minecraft)
    var blockiness: Float

    // MARK: - Burst Timing (temporal variation)

    /// Probability per frame of starting a glitch burst (0-1). E.g., 0.03 = ~1 burst per second at 30fps
    var burstChance: Float

    /// Minimum frames a burst lasts
    var minBurstDuration: Int

    /// Maximum frames a burst lasts
    var maxBurstDuration: Int

    /// Probability of a clean frame even during a burst (breaks up the glitch)
    var cleanFrameChance: Float

    /// How much to vary intensity per burst (0 = consistent, 1 = fully random)
    var intensityVariation: Float

    // MARK: - Randomness

    /// Per-frame seed for repeatable randomness
    var randomSeed: UInt32

    // MARK: - Defaults

    /// Destructive smear - freezes and smears but breathes, original stays visible
    static let `default` = DatamoshParams(
        minHistoryOffset: 15,
        maxHistoryOffset: 70,
        freezeReference: false,
        frozenHistoryOffset: nil,
        blockSize: 10,
        blockMoshProbability: 0.25,
        motionSensitivity: 0.85,
        updateProbability: 0.0,
        smearStrength: 0.45,
        jitterAmount: 0.25,
        feedbackAmount: 0.4,
        blockiness: 0.0,             // Fluid/smooth
        burstChance: 0.008,
        minBurstDuration: 60,
        maxBurstDuration: 240,
        cleanFrameChance: 0.0,
        intensityVariation: 0.5,
        randomSeed: 0
    )

    /// Subtle - gentle destruction, original clearly visible, occasional smear
    static let subtle = DatamoshParams(
        minHistoryOffset: 10,
        maxHistoryOffset: 45,
        freezeReference: false,
        frozenHistoryOffset: nil,
        blockSize: 8,
        blockMoshProbability: 0.15,
        motionSensitivity: 0.95,
        updateProbability: 0.0,
        smearStrength: 0.6,
        jitterAmount: 0.15,
        feedbackAmount: 0.25,
        blockiness: 0.0,             // Fluid/smooth
        burstChance: 0.005,
        minBurstDuration: 45,
        maxBurstDuration: 150,
        cleanFrameChance: 0.0,
        intensityVariation: 0.6,
        randomSeed: 0
    )

    /// Extreme - heavy destruction, long freeze periods, synthetic
    static let extreme = DatamoshParams(
        minHistoryOffset: 30,
        maxHistoryOffset: 120,
        freezeReference: false,
        frozenHistoryOffset: nil,
        blockSize: 14,
        blockMoshProbability: 0.6,
        motionSensitivity: 0.7,
        updateProbability: 0.0,
        smearStrength: 0.1,
        jitterAmount: 0.5,
        feedbackAmount: 0.85,
        blockiness: 0.0,             // Fluid (blocky version separate)
        burstChance: 1.0,
        minBurstDuration: 99999,
        maxBurstDuration: 99999,
        cleanFrameChance: 0.0,
        intensityVariation: 0.0,
        randomSeed: 0
    )

    /// Frozen - locks to history, maximum persistence
    static let frozen = DatamoshParams(
        minHistoryOffset: 60,
        maxHistoryOffset: 60,
        freezeReference: true,
        frozenHistoryOffset: 60,
        blockSize: 12,
        blockMoshProbability: 0.5,
        motionSensitivity: 0.8,
        updateProbability: 0.0,
        smearStrength: 0.15,
        jitterAmount: 0.25,
        feedbackAmount: 0.8,
        blockiness: 0.0,
        burstChance: 0.01,
        minBurstDuration: 120,
        maxBurstDuration: 300,
        cleanFrameChance: 0.0,
        intensityVariation: 0.15,
        randomSeed: 0
    )

    /// Blocky - pixelated/Minecraft style destruction
    static let blocky = DatamoshParams(
        minHistoryOffset: 15,
        maxHistoryOffset: 60,
        freezeReference: false,
        frozenHistoryOffset: nil,
        blockSize: 16,
        blockMoshProbability: 0.35,
        motionSensitivity: 0.8,
        updateProbability: 0.0,
        smearStrength: 0.4,
        jitterAmount: 0.2,
        feedbackAmount: 0.5,
        blockiness: 0.7,             // High blockiness
        burstChance: 0.01,
        minBurstDuration: 60,
        maxBurstDuration: 180,
        cleanFrameChance: 0.0,
        intensityVariation: 0.4,
        randomSeed: 0
    )

    /// Mixed - alternates between fluid and blocky
    static let mixed = DatamoshParams(
        minHistoryOffset: 12,
        maxHistoryOffset: 70,
        freezeReference: false,
        frozenHistoryOffset: nil,
        blockSize: 12,
        blockMoshProbability: 0.3,
        motionSensitivity: 0.85,
        updateProbability: 0.0,
        smearStrength: 0.45,
        jitterAmount: 0.25,
        feedbackAmount: 0.45,
        blockiness: 0.35,            // Moderate - shader will modulate
        burstChance: 0.008,
        minBurstDuration: 60,
        maxBurstDuration: 200,
        cleanFrameChance: 0.0,
        intensityVariation: 0.5,
        randomSeed: 0
    )
}

// MARK: - Metal Buffer Layout

/// GPU-compatible struct layout for Metal shader.
/// Must match the layout in DatamoshShader.metal
struct DatamoshParamsGPU {
    var minHistoryOffset: Int32
    var maxHistoryOffset: Int32
    var freezeReference: Int32      // Bool as int (0 or 1)
    var frozenHistoryOffset: Int32  // -1 if nil
    var blockSize: Int32
    var blockMoshProbability: Float
    var motionSensitivity: Float
    var updateProbability: Float
    var smearStrength: Float
    var jitterAmount: Float
    var feedbackAmount: Float
    var blockiness: Float           // 0 = fluid, 1 = very blocky
    var randomSeed: UInt32
    var textureWidth: Int32
    var textureHeight: Int32

    init(from params: DatamoshParams, width: Int, height: Int) {
        self.minHistoryOffset = Int32(params.minHistoryOffset)
        self.maxHistoryOffset = Int32(params.maxHistoryOffset)
        self.freezeReference = params.freezeReference ? 1 : 0
        self.frozenHistoryOffset = Int32(params.frozenHistoryOffset ?? -1)
        self.blockSize = Int32(params.blockSize)
        self.blockMoshProbability = params.blockMoshProbability
        self.motionSensitivity = params.motionSensitivity
        self.updateProbability = params.updateProbability
        self.smearStrength = params.smearStrength
        self.jitterAmount = params.jitterAmount
        self.feedbackAmount = params.feedbackAmount
        self.blockiness = params.blockiness
        self.randomSeed = params.randomSeed
        self.textureWidth = Int32(width)
        self.textureHeight = Int32(height)
    }
}

