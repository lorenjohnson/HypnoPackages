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

// MARK: - Noise Helpers

// Fast hash for pseudo-random values
static inline float hash(float2 p, uint seed) {
    float3 p3 = fract(float3(p.xyx) * 0.1031);
    p3 += dot(p3, p3.yzx + 33.33 + float(seed) * 0.001);
    return fract((p3.x + p3.y) * p3.z);
}

#endif /* TransitionCommon_h */
