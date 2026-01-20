//
//  TransitionCommon.h
//  HypnoCore
//
//  Shared types and helpers for Metal transition shaders.
//

#ifndef TransitionCommon_h
#define TransitionCommon_h

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

// MARK: - Coordinate Mapping

// Map an output-space pixel coordinate into the coordinate system of a source texture.
// This keeps transitions robust if output textures ever differ in size (e.g., a settings
// change while transitioning). Mapping is "stretch-to-fit" with clamp-to-edge semantics.
static inline uint2 mapCoord(uint2 outGid, int outW, int outH, int srcW, int srcH) {
    // Avoid divide-by-zero in weird edge cases.
    float ow = float(max(outW, 1));
    float oh = float(max(outH, 1));

    float2 uv = (float2(float(outGid.x), float(outGid.y)) + 0.5) / float2(ow, oh);

    int x = int(floor(uv.x * float(max(srcW, 1))));
    int y = int(floor(uv.y * float(max(srcH, 1))));

    x = clamp(x, 0, max(srcW - 1, 0));
    y = clamp(y, 0, max(srcH - 1, 0));
    return uint2(uint(x), uint(y));
}

static inline uint2 mapCoord(float2 outPx, int outW, int outH, int srcW, int srcH) {
    float ow = float(max(outW, 1));
    float oh = float(max(outH, 1));

    float2 uv = (outPx + 0.5) / float2(ow, oh);

    int x = int(floor(uv.x * float(max(srcW, 1))));
    int y = int(floor(uv.y * float(max(srcH, 1))));

    x = clamp(x, 0, max(srcW - 1, 0));
    y = clamp(y, 0, max(srcH - 1, 0));
    return uint2(uint(x), uint(y));
}

// MARK: - Noise Helpers

// Fast hash for pseudo-random values
static inline float hash(float2 p, uint seed) {
    float3 p3 = fract(float3(p.xyx) * 0.1031);
    p3 += dot(p3, p3.yzx + 33.33 + float(seed) * 0.001);
    return fract((p3.x + p3.y) * p3.z);
}

#endif /* TransitionCommon_h */
