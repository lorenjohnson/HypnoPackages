#include <metal_stdlib>
using namespace metal;

struct HypnoParams {
    float spectral;
    float smear;
    int textureWidth;
    int textureHeight;
};

inline float4 sampleTexture(
    texture2d<float, access::sample> texture,
    float2 uv
) {
    constexpr sampler samplerLinear(mag_filter::linear, min_filter::linear, address::clamp_to_edge);
    return texture.sample(samplerLinear, uv);
}

inline float3 smearBlend(
    float2 uv,
    float smear,
    texture2d<float, access::sample> currentTexture,
    texture2d<float, access::sample> historyA,
    texture2d<float, access::sample> historyB,
    texture2d<float, access::sample> historyC,
    texture2d<float, access::sample> historyD
) {
    float4 current = sampleTexture(currentTexture, uv);
    float4 a = sampleTexture(historyA, uv);
    float4 b = sampleTexture(historyB, uv);
    float4 c = sampleTexture(historyC, uv);
    float4 d = sampleTexture(historyD, uv);

    float smearClamped = clamp(smear, 0.0, 1.5);
    float w0 = 1.0;
    float w1 = smearClamped * 0.52;
    float w2 = smearClamped * 0.34;
    float w3 = smearClamped * 0.22;
    float w4 = smearClamped * 0.12;

    float3 accum = current.rgb * w0
        + a.rgb * w1
        + b.rgb * w2
        + c.rgb * w3
        + d.rgb * w4;

    float total = w0 + w1 + w2 + w3 + w4;
    return accum / max(total, 0.0001);
}

kernel void render(
    texture2d<float, access::sample> currentTexture [[texture(0)]],
    texture2d<float, access::sample> historyA [[texture(1)]],
    texture2d<float, access::sample> historyB [[texture(2)]],
    texture2d<float, access::sample> historyC [[texture(3)]],
    texture2d<float, access::sample> historyD [[texture(4)]],
    texture2d<float, access::write> outputTexture [[texture(5)]],
    constant HypnoParams& params [[buffer(0)]],
    uint2 gid [[thread_position_in_grid]]
) {
    if (gid.x >= uint(params.textureWidth) || gid.y >= uint(params.textureHeight)) {
        return;
    }

    float2 texSize = float2(params.textureWidth, params.textureHeight);
    float2 uv = (float2(gid) + 0.5) / texSize;

    float3 center = smearBlend(
        uv,
        params.smear,
        currentTexture,
        historyA,
        historyB,
        historyC,
        historyD
    );

    float split = clamp(params.spectral, 0.0, 1.0);
    float pixelOffset = mix(0.0, 10.0, split);
    float2 uvOffset = float2(pixelOffset / max(texSize.x, 1.0), 0.0);

    float3 older = smearBlend(
        uv - uvOffset,
        params.smear * 0.85,
        historyA,
        historyB,
        historyC,
        historyD,
        historyD
    );

    float3 newer = smearBlend(
        uv + uvOffset,
        params.smear * 0.85,
        currentTexture,
        currentTexture,
        historyA,
        historyB,
        historyC
    );

    float3 spectralColor = float3(older.r, center.g, newer.b);
    float3 result = mix(center, spectralColor, split);

    float alpha = sampleTexture(currentTexture, uv).a;
    outputTexture.write(float4(clamp(result, 0.0, 1.0), alpha), gid);
}
