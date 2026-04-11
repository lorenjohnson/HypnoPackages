#include <metal_stdlib>
using namespace metal;

struct HypnoParams {
    float jitterAmount;
    float lineNoise;
    float ghosting;
    float sparkle;
    int frameIndex;
    int textureWidth;
    int textureHeight;
};

inline float hash12(float2 p) {
    return fract(sin(dot(p, float2(127.1, 311.7))) * 43758.5453123);
}

kernel void render(
    texture2d<float, access::sample> inputTexture [[texture(0)]],
    texture2d<float, access::write> outputTexture [[texture(1)]],
    constant HypnoParams& params [[buffer(0)]],
    uint2 gid [[thread_position_in_grid]]
) {
    if (gid.x >= uint(params.textureWidth) || gid.y >= uint(params.textureHeight)) {
        return;
    }

    constexpr sampler s(mag_filter::linear, min_filter::linear, address::clamp_to_edge);
    float2 texSize = float2(params.textureWidth, params.textureHeight);
    float2 texel = 1.0 / max(texSize, float2(1.0));
    float2 uv = (float2(gid) + 0.5) * texel;
    float t = float(params.frameIndex) * 0.0166667;

    float jitter = clamp(params.jitterAmount, 0.0, 1.0);
    float noise = hash12(float2(float(gid.y), t * 41.0));
    float lineWave = sin(float(gid.y) * 0.12 + t * 9.0);
    float xOffsetPx = (noise - 0.5 + 0.5 * lineWave) * 3.5 * jitter;
    float2 jitterUV = clamp(uv + float2(xOffsetPx * texel.x, 0.0), float2(0.0), float2(1.0));

    float4 base = inputTexture.sample(s, jitterUV);

    // Analog-style trailing ghost (right side).
    float ghost = clamp(params.ghosting, 0.0, 1.0);
    float2 ghostUV = clamp(jitterUV + float2((1.5 + 4.0 * ghost) * texel.x, 0.0), float2(0.0), float2(1.0));
    float3 ghostRGB = inputTexture.sample(s, ghostUV).rgb;
    float3 rgb = mix(base.rgb, ghostRGB, 0.32 * ghost);

    // Row-dependent luma hiss and bias.
    float lineNoiseAmt = clamp(params.lineNoise, 0.0, 1.0);
    float rowRand = hash12(float2(float(gid.y) * 0.37, t * 23.0));
    float pxRand = hash12(float2(float(gid.x) + t * 97.0, float(gid.y) * 1.7));
    float hiss = (pxRand - 0.5) * 0.10 * lineNoiseAmt;
    float rowBias = (rowRand - 0.5) * 0.06 * lineNoiseAmt;
    rgb += float3(hiss + rowBias);

    // Occasional bright speckles.
    float sparkleAmt = clamp(params.sparkle, 0.0, 1.0);
    float sparkRand = hash12(float2(float(gid.x) * 5.1 + t * 31.0, float(gid.y) * 3.7));
    if (sparkRand > (0.9975 - 0.01 * sparkleAmt)) {
        rgb += float3(0.35 + 0.35 * sparkleAmt);
    }

    outputTexture.write(float4(clamp(rgb, 0.0, 1.0), base.a), gid);
}
