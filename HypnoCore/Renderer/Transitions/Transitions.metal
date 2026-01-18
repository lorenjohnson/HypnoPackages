//
//  Transitions.metal
//  HypnoCore
//
//  Metal compute shaders for video transitions.
//  Each kernel blends outgoing and incoming textures based on progress.
//

#include <metal_stdlib>
using namespace metal;

// MARK: - Parameters

struct TransitionParams {
    float progress;     // 0.0 to 1.0
    int width;
    int height;
    uint seed;          // Random seed for noise
    float softness;     // Edge softness (0.0 to 0.5)
    float _padding;
};

// MARK: - Noise Functions (static to avoid symbol conflicts with other shaders)

// Hash function for pseudo-random noise
static inline float transitionHash(float2 p, uint seed) {
    float3 p3 = fract(float3(p.xyx) * 0.1031);
    p3 += dot(p3, p3.yzx + 33.33 + float(seed) * 0.001);
    return fract((p3.x + p3.y) * p3.z);
}

// Smooth noise
static inline float transitionNoise(float2 p, uint seed) {
    float2 i = floor(p);
    float2 f = fract(p);
    f = f * f * (3.0 - 2.0 * f);

    float a = transitionHash(i, seed);
    float b = transitionHash(i + float2(1.0, 0.0), seed);
    float c = transitionHash(i + float2(0.0, 1.0), seed);
    float d = transitionHash(i + float2(1.0, 1.0), seed);

    return mix(mix(a, b, f.x), mix(c, d, f.x), f.y);
}

// MARK: - Crossfade Transition

kernel void transitionCrossfade(
    texture2d<float, access::read> outgoing [[texture(0)]],
    texture2d<float, access::read> incoming [[texture(1)]],
    texture2d<float, access::write> output [[texture(2)]],
    constant TransitionParams& params [[buffer(0)]],
    uint2 gid [[thread_position_in_grid]]
) {
    if (gid.x >= uint(params.width) || gid.y >= uint(params.height)) {
        return;
    }

    float4 a = outgoing.read(gid);
    float4 b = incoming.read(gid);

    // Simple linear blend
    float4 result = mix(a, b, params.progress);
    output.write(result, gid);
}

// MARK: - Punk Transition (Stepped/Jittery)

kernel void transitionPunk(
    texture2d<float, access::read> outgoing [[texture(0)]],
    texture2d<float, access::read> incoming [[texture(1)]],
    texture2d<float, access::write> output [[texture(2)]],
    constant TransitionParams& params [[buffer(0)]],
    uint2 gid [[thread_position_in_grid]]
) {
    if (gid.x >= uint(params.width) || gid.y >= uint(params.height)) {
        return;
    }

    float4 a = outgoing.read(gid);
    float4 b = incoming.read(gid);

    // Quantize progress to create stepped effect
    float steps = 8.0;
    float quantized = floor(params.progress * steps) / steps;

    // Add per-pixel noise for jitter
    float2 uv = float2(gid) / float2(params.width, params.height);
    float n = transitionHash(uv * 100.0, params.seed);
    float threshold = quantized + (n - 0.5) * 0.15;

    // Binary switch with some noise
    float4 result = params.progress > threshold ? b : a;
    output.write(result, gid);
}

// MARK: - Wipe Transitions

kernel void transitionWipeRight(
    texture2d<float, access::read> outgoing [[texture(0)]],
    texture2d<float, access::read> incoming [[texture(1)]],
    texture2d<float, access::write> output [[texture(2)]],
    constant TransitionParams& params [[buffer(0)]],
    uint2 gid [[thread_position_in_grid]]
) {
    if (gid.x >= uint(params.width) || gid.y >= uint(params.height)) {
        return;
    }

    float4 a = outgoing.read(gid);
    float4 b = incoming.read(gid);

    // Wipe from left to right
    float normalized = float(gid.x) / float(params.width);
    float edge = params.progress;
    float blend = smoothstep(edge - params.softness, edge + params.softness, normalized);

    float4 result = mix(a, b, blend);
    output.write(result, gid);
}

kernel void transitionWipeLeft(
    texture2d<float, access::read> outgoing [[texture(0)]],
    texture2d<float, access::read> incoming [[texture(1)]],
    texture2d<float, access::write> output [[texture(2)]],
    constant TransitionParams& params [[buffer(0)]],
    uint2 gid [[thread_position_in_grid]]
) {
    if (gid.x >= uint(params.width) || gid.y >= uint(params.height)) {
        return;
    }

    float4 a = outgoing.read(gid);
    float4 b = incoming.read(gid);

    // Wipe from right to left
    float normalized = 1.0 - float(gid.x) / float(params.width);
    float edge = params.progress;
    float blend = smoothstep(edge - params.softness, edge + params.softness, normalized);

    float4 result = mix(a, b, blend);
    output.write(result, gid);
}

kernel void transitionWipeDown(
    texture2d<float, access::read> outgoing [[texture(0)]],
    texture2d<float, access::read> incoming [[texture(1)]],
    texture2d<float, access::write> output [[texture(2)]],
    constant TransitionParams& params [[buffer(0)]],
    uint2 gid [[thread_position_in_grid]]
) {
    if (gid.x >= uint(params.width) || gid.y >= uint(params.height)) {
        return;
    }

    float4 a = outgoing.read(gid);
    float4 b = incoming.read(gid);

    // Wipe from top to bottom
    float normalized = float(gid.y) / float(params.height);
    float edge = params.progress;
    float blend = smoothstep(edge - params.softness, edge + params.softness, normalized);

    float4 result = mix(a, b, blend);
    output.write(result, gid);
}

kernel void transitionWipeUp(
    texture2d<float, access::read> outgoing [[texture(0)]],
    texture2d<float, access::read> incoming [[texture(1)]],
    texture2d<float, access::write> output [[texture(2)]],
    constant TransitionParams& params [[buffer(0)]],
    uint2 gid [[thread_position_in_grid]]
) {
    if (gid.x >= uint(params.width) || gid.y >= uint(params.height)) {
        return;
    }

    float4 a = outgoing.read(gid);
    float4 b = incoming.read(gid);

    // Wipe from bottom to top
    float normalized = 1.0 - float(gid.y) / float(params.height);
    float edge = params.progress;
    float blend = smoothstep(edge - params.softness, edge + params.softness, normalized);

    float4 result = mix(a, b, blend);
    output.write(result, gid);
}

// MARK: - Dissolve Transition (Noise-based)

kernel void transitionDissolve(
    texture2d<float, access::read> outgoing [[texture(0)]],
    texture2d<float, access::read> incoming [[texture(1)]],
    texture2d<float, access::write> output [[texture(2)]],
    constant TransitionParams& params [[buffer(0)]],
    uint2 gid [[thread_position_in_grid]]
) {
    if (gid.x >= uint(params.width) || gid.y >= uint(params.height)) {
        return;
    }

    float4 a = outgoing.read(gid);
    float4 b = incoming.read(gid);

    // Multi-octave noise for organic dissolve
    float2 uv = float2(gid) / float2(params.width, params.height);
    float n = 0.0;
    n += transitionNoise(uv * 10.0, params.seed) * 0.5;
    n += transitionNoise(uv * 20.0, params.seed + 1) * 0.25;
    n += transitionNoise(uv * 40.0, params.seed + 2) * 0.125;
    n = n / 0.875;  // Normalize

    // Threshold based on progress
    float threshold = params.progress;
    float blend = smoothstep(threshold - 0.1, threshold + 0.1, n);

    float4 result = mix(a, b, blend);
    output.write(result, gid);
}
