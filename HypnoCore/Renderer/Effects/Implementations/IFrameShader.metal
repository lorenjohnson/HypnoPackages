//
//  IFrameShader.metal
//  Hypnograph
//
//  Temporal ghosting/drift with content-adaptive I-frames.
//  Areas reset when difference exceeds threshold, otherwise accumulate damage.
//

#include <metal_stdlib>
using namespace metal;

struct IFrameParams {
    int textureWidth;
    int textureHeight;
    float stickiness;      // Base persistence (0=follow, 1=frozen)
    float quality;         // Compression harshness (1=clean, 0=destroyed)
    float glitch;          // Motion-driven trail intensity (0=none, 1=heavy trails)
    float diffThreshold;   // Difference threshold for adaptive I-frame (0=always reset, 1=never)
    int isIFrame;          // 1 = force reset all, 0 = adaptive
    int frameNumber;       // For temporal variation
};

// Simple hash for dithering
float hash(float2 p) {
    return fract(sin(dot(p, float2(127.1, 311.7))) * 43758.5453);
}

// Temporal ghosting with motion-driven trails
kernel void iframeAccumulateKernel(
    texture2d<float, access::sample> currentTexture [[texture(0)]],
    texture2d<float, access::read_write> referenceTexture [[texture(1)]],
    texture2d<float, access::write> outputTexture [[texture(2)]],
    constant IFrameParams& params [[buffer(0)]],
    uint2 gid [[thread_position_in_grid]]
) {
    if (gid.x >= uint(params.textureWidth) || gid.y >= uint(params.textureHeight)) {
        return;
    }

    constexpr sampler texSampler(mag_filter::linear, min_filter::linear, address::clamp_to_edge);
    float2 texSize = float2(params.textureWidth, params.textureHeight);
    float2 uv = (float2(gid) + 0.5) / texSize;

    float4 current = currentTexture.sample(texSampler, uv);
    float4 reference = referenceTexture.read(gid);
    float4 result;

    // Compute frame difference
    float3 diff = abs(current.rgb - reference.rgb);
    float motion = (diff.r + diff.g + diff.b) / 3.0;  // 0 = static, 1 = full change

    // Content-adaptive I-frame: reset this pixel if difference exceeds threshold
    // Low threshold = resets easily (less damage accumulation)
    // High threshold = rarely resets (more damage accumulation)
    bool localReset = (params.isIFrame == 1) || (motion > params.diffThreshold);

    if (localReset) {
        // This pixel resets to current (takes new snapshot)
        result = current;
        referenceTexture.write(result, gid);
        outputTexture.write(result, gid);
        return;
    }

    // Below threshold: accumulate damage, don't update to current
    // Base blend from stickiness
    float baseBlend = 1.0 - params.stickiness;

    // Motion-driven trails: where there's motion, make it stickier
    float motionStick = motion * params.glitch * 2.0;
    float blend = baseBlend * (1.0 - clamp(motionStick, 0.0, 0.95));

    // Blend toward current (or stick with reference in motion areas)
    float3 blended = mix(reference.rgb, current.rgb, blend);

    // At high glitch, also smear based on motion direction
    if (params.glitch > 0.3) {
        // Sample neighbors to estimate motion direction
        float2 px = 1.0 / texSize;
        float4 refL = referenceTexture.read(uint2(clamp(float2(gid) + float2(-2, 0), float2(0), texSize - 1)));
        float4 refR = referenceTexture.read(uint2(clamp(float2(gid) + float2(2, 0), float2(0), texSize - 1)));
        float4 refU = referenceTexture.read(uint2(clamp(float2(gid) + float2(0, -2), float2(0), texSize - 1)));
        float4 refD = referenceTexture.read(uint2(clamp(float2(gid) + float2(0, 2), float2(0), texSize - 1)));

        // Gradient of reference (approximates where things came from)
        float2 gradient = float2(
            dot(refR.rgb - refL.rgb, float3(1.0)),
            dot(refD.rgb - refU.rgb, float3(1.0))
        );

        // In motion areas, smear along gradient
        if (motion > 0.05) {
            float smearAmount = params.glitch * motion * 0.5;
            float2 smearOffset = normalize(gradient + 0.001) * smearAmount * 0.02;
            float2 smearUV = clamp(uv + smearOffset, float2(0.0), float2(1.0));
            float4 smeared = referenceTexture.read(uint2(smearUV * texSize));
            blended = mix(blended, smeared.rgb, smearAmount);
        }
    }

    // Quality controls compression artifacts
    if (params.quality < 0.9) {
        float levels = max(4.0, params.quality * params.quality * 256.0);
        float dither = (hash(float2(gid) + float(params.frameNumber) * 0.1) - 0.5) / levels;
        blended = floor((blended + dither) * levels + 0.5) / levels;
    }

    result.rgb = clamp(blended, 0.0, 1.0);
    result.a = current.a;

    referenceTexture.write(result, gid);
    outputTexture.write(result, gid);
}

