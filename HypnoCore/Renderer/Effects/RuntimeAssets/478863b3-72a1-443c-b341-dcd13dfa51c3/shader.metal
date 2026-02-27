#include <metal_stdlib>
using namespace metal;

struct HypnoParams {
    float intensity;
    int trailLength;
    float blurAmount;
    int textureWidth;
    int textureHeight;
};

inline float4 sampleHistoryByIndex(
    int index,
    float2 uv,
    texture2d<float, access::sample> h0,
    texture2d<float, access::sample> h1,
    texture2d<float, access::sample> h2,
    texture2d<float, access::sample> h3,
    texture2d<float, access::sample> h4,
    texture2d<float, access::sample> h5,
    texture2d<float, access::sample> h6,
    texture2d<float, access::sample> h7
) {
    constexpr sampler samplerLinear(mag_filter::linear, min_filter::linear, address::clamp_to_edge);
    switch (index) {
        case 0: return h0.sample(samplerLinear, uv);
        case 1: return h1.sample(samplerLinear, uv);
        case 2: return h2.sample(samplerLinear, uv);
        case 3: return h3.sample(samplerLinear, uv);
        case 4: return h4.sample(samplerLinear, uv);
        case 5: return h5.sample(samplerLinear, uv);
        case 6: return h6.sample(samplerLinear, uv);
        default: return h7.sample(samplerLinear, uv);
    }
}

inline float3 sampleBlurredHistory(
    int index,
    float2 uv,
    float radiusPixels,
    float2 texSize,
    texture2d<float, access::sample> h0,
    texture2d<float, access::sample> h1,
    texture2d<float, access::sample> h2,
    texture2d<float, access::sample> h3,
    texture2d<float, access::sample> h4,
    texture2d<float, access::sample> h5,
    texture2d<float, access::sample> h6,
    texture2d<float, access::sample> h7
) {
    float4 center = sampleHistoryByIndex(index, uv, h0, h1, h2, h3, h4, h5, h6, h7);
    if (radiusPixels <= 0.5) {
        return center.rgb;
    }

    float2 radiusUV = float2(radiusPixels / max(texSize.x, 1.0), radiusPixels / max(texSize.y, 1.0));
    float4 left = sampleHistoryByIndex(index, uv + float2(-radiusUV.x, 0.0), h0, h1, h2, h3, h4, h5, h6, h7);
    float4 right = sampleHistoryByIndex(index, uv + float2(radiusUV.x, 0.0), h0, h1, h2, h3, h4, h5, h6, h7);
    float4 up = sampleHistoryByIndex(index, uv + float2(0.0, -radiusUV.y), h0, h1, h2, h3, h4, h5, h6, h7);
    float4 down = sampleHistoryByIndex(index, uv + float2(0.0, radiusUV.y), h0, h1, h2, h3, h4, h5, h6, h7);
    return (center.rgb + left.rgb + right.rgb + up.rgb + down.rgb) / 5.0;
}

kernel void render(
    texture2d<float, access::sample> currentTexture [[texture(0)]],
    texture2d<float, access::sample> history0 [[texture(1)]],
    texture2d<float, access::sample> history1 [[texture(2)]],
    texture2d<float, access::sample> history2 [[texture(3)]],
    texture2d<float, access::sample> history3 [[texture(4)]],
    texture2d<float, access::sample> history4 [[texture(5)]],
    texture2d<float, access::sample> history5 [[texture(6)]],
    texture2d<float, access::sample> history6 [[texture(7)]],
    texture2d<float, access::sample> history7 [[texture(8)]],
    texture2d<float, access::write> outputTexture [[texture(9)]],
    constant HypnoParams& params [[buffer(0)]],
    uint2 gid [[thread_position_in_grid]]
) {
    if (gid.x >= uint(params.textureWidth) || gid.y >= uint(params.textureHeight)) {
        return;
    }

    constexpr sampler samplerLinear(mag_filter::linear, min_filter::linear, address::clamp_to_edge);
    float2 texSize = float2(params.textureWidth, params.textureHeight);
    float2 uv = (float2(gid) + 0.5) / texSize;

    float4 current = currentTexture.sample(samplerLinear, uv);
    float3 accum = current.rgb;

    int sampleCount = clamp(params.trailLength, 1, 8);

    for (int i = 0; i < sampleCount; i++) {
        float age = float(i + 1) / float(sampleCount);
        float opacity = clamp(params.intensity * (1.0 - age) * 0.4, 0.0, 0.95);
        float blurRadius = max(params.blurAmount * age * params.intensity, 0.0);
        float3 hist = sampleBlurredHistory(
            i,
            uv,
            blurRadius,
            texSize,
            history0, history1, history2, history3,
            history4, history5, history6, history7
        );
        accum = mix(accum, hist, opacity);
    }

    outputTexture.write(float4(clamp(accum, 0.0, 1.0), current.a), gid);
}
