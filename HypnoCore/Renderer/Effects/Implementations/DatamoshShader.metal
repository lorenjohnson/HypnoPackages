//
//  DatamoshShader.metal
//  Hypnograph
//
//  Temporal smear/displacement effect. Motion areas blend with history,
//  creating flowing, dreamy transitions.
//

#include <metal_stdlib>
using namespace metal;

// MARK: - Parameters

struct DatamoshParams {
    int minHistoryOffset;
    int maxHistoryOffset;
    int freezeReference;
    int frozenHistoryOffset;
    int blockSize;               // Blur radius for motion detection
    float blockMoshProbability;  // Base displacement strength
    float motionSensitivity;     // How much motion increases effect
    float updateProbability;     // Unused
    float smearStrength;         // 0 = more history, 1 = more current
    float jitterAmount;          // Subtle UV drift
    float feedbackAmount;        // Blend with previous output
    float blockiness;            // 0 = fluid, 1 = very blocky/pixelated
    uint randomSeed;
    int textureWidth;
    int textureHeight;
};

// MARK: - Sampling

inline float4 sampleTexture(texture2d<float, access::sample> tex,
                            float2 uv, int width, int height) {
    constexpr sampler s(coord::pixel, address::clamp_to_edge, filter::linear);
    float2 clamped = clamp(uv, float2(0.5), float2(width - 0.5, height - 0.5));
    return tex.sample(s, clamped);
}

// Fast 5-tap blur (center + 4 diagonals)
inline float4 sampleBlurred5(texture2d<float, access::sample> tex,
                             float2 uv, float radius, int width, int height) {
    float4 center = sampleTexture(tex, uv, width, height);
    float4 tl = sampleTexture(tex, uv + float2(-radius, -radius), width, height);
    float4 tr = sampleTexture(tex, uv + float2(radius, -radius), width, height);
    float4 bl = sampleTexture(tex, uv + float2(-radius, radius), width, height);
    float4 br = sampleTexture(tex, uv + float2(radius, radius), width, height);
    return (center * 2.0 + tl + tr + bl + br) / 6.0;
}

// MARK: - Noise

// Simple hash for pseudo-random values
inline float hash(float2 p, uint seed) {
    float3 p3 = fract(float3(p.x, p.y, float(seed)) * float3(0.1031, 0.1030, 0.0973));
    p3 += dot(p3, p3.yzx + 33.33);
    return fract((p3.x + p3.y) * p3.z);
}

// Smooth noise
inline float noise(float2 p, uint seed) {
    float2 i = floor(p);
    float2 f = fract(p);
    f = f * f * (3.0 - 2.0 * f);  // Smooth interpolation

    float a = hash(i, seed);
    float b = hash(i + float2(1.0, 0.0), seed);
    float c = hash(i + float2(0.0, 1.0), seed);
    float d = hash(i + float2(1.0, 1.0), seed);

    return mix(mix(a, b, f.x), mix(c, d, f.x), f.y);
}

// MARK: - Motion Detection

// Returns motion magnitude (0-1) based on frame difference
inline float calculateMotion(texture2d<float, access::sample> current,
                             texture2d<float, access::sample> history,
                             float2 uv, float blurRadius,
                             int width, int height) {
    float4 curr = sampleBlurred5(current, uv, blurRadius, width, height);
    float4 hist = sampleBlurred5(history, uv, blurRadius, width, height);

    // Color difference as motion indicator
    float3 diff = abs(curr.rgb - hist.rgb);
    float motion = (diff.r + diff.g + diff.b) / 3.0;

    return saturate(motion * 3.0);  // Boost motion detection
}

// MARK: - Kernel

kernel void datamoshKernel(
    texture2d<float, access::sample> currentFrame [[texture(0)]],
    texture2d<float, access::sample> historyFrame [[texture(1)]],
    texture2d<float, access::sample> previousOutput [[texture(2)]],
    texture2d<float, access::write> output [[texture(3)]],
    constant DatamoshParams& params [[buffer(0)]],
    uint2 gid [[thread_position_in_grid]]
) {
    if (gid.x >= uint(params.textureWidth) || gid.y >= uint(params.textureHeight)) {
        return;
    }

    int x = int(gid.x);
    int y = int(gid.y);
    float2 uv = float2(x, y) + 0.5;
    int width = params.textureWidth;
    int height = params.textureHeight;
    uint seed = params.randomSeed;

    // Calculate motion at this pixel (where things are actually changing)
    float blurRadius = float(max(6, params.blockSize));
    float motion = calculateMotion(currentFrame, historyFrame, uv, blurRadius, width, height);

    // Effect strength: base amount PLUS motion boost
    float baseEffect = params.blockMoshProbability;
    float motionBoost = motion * params.motionSensitivity * 1.2;
    float effectStrength = saturate(baseEffect + motionBoost);

    // Check if previous output already has destruction here
    float4 prevColor = sampleTexture(previousOutput, uv, width, height);
    float4 currColor = sampleTexture(currentFrame, uv, width, height);
    float3 prevDiff = abs(prevColor.rgb - currColor.rgb);
    float alreadyDestroyed = (prevDiff.r + prevDiff.g + prevDiff.b) / 3.0;

    // Persistence: destroyed areas stay destroyed, but with decay
    // Lower feedbackAmount = faster recovery to clean image
    float persistenceBoost = alreadyDestroyed * params.feedbackAmount * 1.2;
    // But always decay a bit toward clean (allows breathing)
    persistenceBoost *= 0.85;
    effectStrength = max(effectStrength, persistenceBoost);

    // smearStrength acts as a ceiling on how destroyed things can get
    // Higher smearStrength = more current frame visible = less total destruction
    effectStrength = effectStrength * (1.0 - params.smearStrength * 0.5);

    // Very low effect = pass through clean
    if (effectStrength < 0.05) {
        output.write(float4(currColor.rgb, 1.0), gid);
        return;
    }

    // Noise-based displacement - organic, not geometric
    float noiseScale = 0.02;  // Controls blob size
    float2 noiseCoord = float2(x, y) * noiseScale;

    // Multi-octave noise for more organic feel
    float n1 = noise(noiseCoord, seed);
    float n2 = noise(noiseCoord * 2.3 + 17.0, seed + 1);
    float n3 = noise(noiseCoord * 0.7 + 31.0, seed + 2);

    // Displacement direction from noise (circular, not diamond)
    float angle = (n1 + n2 * 0.5) * 6.28318;  // Random angle
    float magnitude = (n2 + n3 * 0.3) * effectStrength * (1.0 - params.smearStrength);

    // Scale displacement - stronger in motion areas
    float dispAmount = magnitude * 40.0 * motion;
    float2 displacement = float2(cos(angle), sin(angle)) * dispAmount;

    // Add some randomness/jitter
    if (params.jitterAmount > 0.0) {
        float jitterNoise = noise(noiseCoord * 4.0, seed + 3);
        displacement += float2(jitterNoise - 0.5, noise(noiseCoord * 4.0 + 50.0, seed + 4) - 0.5)
                       * params.jitterAmount * 20.0 * motion;
    }

    // Sample from displaced position
    float2 sampleUV = uv + displacement;

    // Apply blockiness - snap UV to grid for pixelated look
    if (params.blockiness > 0.0) {
        // Block size scales from 4 to 32 pixels based on blockiness
        float blockPixels = mix(4.0, 32.0, params.blockiness);

        // Snap UV to block grid
        float2 blockyUV = floor(sampleUV / blockPixels) * blockPixels + blockPixels * 0.5;

        // Mix between smooth and blocky based on blockiness parameter
        sampleUV = mix(sampleUV, blockyUV, params.blockiness);
    }

    // Sample from various sources at displaced position
    float4 prevDisplaced = sampleTexture(previousOutput, sampleUV, width, height);
    float4 histDisplaced = sampleTexture(historyFrame, sampleUV, width, height);
    float4 currDisplaced = sampleTexture(currentFrame, sampleUV, width, height);

    // Balance between destruction and keeping original visible
    // effectStrength controls how much we destroy
    // smearStrength controls how much current frame shows through

    // Start with mix of history and current (displaced)
    float historyWeight = effectStrength * 0.6;
    float4 result = mix(currDisplaced, histDisplaced, historyWeight);

    // Add smear from previous output
    float smearAmount = params.feedbackAmount * effectStrength * 0.7;
    result = mix(result, prevDisplaced, saturate(smearAmount));

    // Let current frame show through based on smearStrength
    // Higher smearStrength = more current visible = image stays identifiable
    float currentBleed = params.smearStrength * (1.0 - effectStrength * 0.5);
    result = mix(result, currDisplaced, currentBleed);

    // Light persistence from non-displaced previous (subtle)
    float4 prevDirect = sampleTexture(previousOutput, uv, width, height);
    float stickiness = params.feedbackAmount * 0.25;
    result = mix(result, prevDirect, saturate(stickiness));

    // Subtle color shift only at high destruction
    if (effectStrength > 0.7) {
        float shift = (effectStrength - 0.7) * 0.1;
        result.r = mix(result.r, result.g, shift);
    }

    output.write(float4(result.rgb, 1.0), gid);
}