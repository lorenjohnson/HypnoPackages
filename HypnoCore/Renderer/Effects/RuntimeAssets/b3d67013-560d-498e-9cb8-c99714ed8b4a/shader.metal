#include <metal_stdlib>
using namespace metal;

struct HypnoParams {
    float offsetAmount;
    bool animated;
    float timeSeconds;
    int textureWidth;
    int textureHeight;
};

inline float animatedPhase(float t) {
    float slow = sin(t * 0.7);
    float medium = sin(t * 2.3 + 1.5) * 0.4;
    float fast = sin(t * 7.1 + 3.0) * 0.15;
    float erratic = sin(t * 13.7 + t * 0.3) * 0.1;
    float combined = slow + medium + fast + erratic;
    return (combined + 1.0) * 0.45 + 0.1;
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

    constexpr sampler samplerLinear(mag_filter::linear, min_filter::linear, address::clamp_to_edge);

    float2 texSize = float2(params.textureWidth, params.textureHeight);
    float2 uv = (float2(gid) + 0.5) / texSize;

    float offsetPixels = params.offsetAmount;
    if (params.animated) {
        offsetPixels *= animatedPhase(params.timeSeconds);
    }
    float offsetUV = offsetPixels / max(texSize.x, 1.0);

    float4 center = inputTexture.sample(samplerLinear, uv);
    float4 redShifted = inputTexture.sample(samplerLinear, uv + float2(offsetUV, 0.0));
    float4 blueShifted = inputTexture.sample(samplerLinear, uv - float2(offsetUV, 0.0));

    float3 rgb = float3(redShifted.r, center.g, blueShifted.b);
    outputTexture.write(float4(clamp(rgb, 0.0, 1.0), center.a), gid);
}
