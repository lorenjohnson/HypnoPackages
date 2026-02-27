#include <metal_stdlib>
using namespace metal;

struct HypnoParams {
    int channelOffset;
    float intensity;
    int textureWidth;
    int textureHeight;
};

kernel void render(
    texture2d<float, access::sample> currentTexture [[texture(0)]],
    texture2d<float, access::sample> greenTexture [[texture(1)]],
    texture2d<float, access::sample> blueTexture [[texture(2)]],
    texture2d<float, access::write> outputTexture [[texture(3)]],
    constant HypnoParams& params [[buffer(0)]],
    uint2 gid [[thread_position_in_grid]]
) {
    if (gid.x >= uint(params.textureWidth) || gid.y >= uint(params.textureHeight)) {
        return;
    }

    constexpr sampler samplerLinear(mag_filter::linear, min_filter::linear, address::clamp_to_edge);
    float2 uv = (float2(gid) + 0.5) / float2(params.textureWidth, params.textureHeight);

    float4 c = currentTexture.sample(samplerLinear, uv);
    float4 g = greenTexture.sample(samplerLinear, uv);
    float4 b = blueTexture.sample(samplerLinear, uv);

    float intensity = clamp(params.intensity, 0.0, 2.0);
    float3 result = float3(
        c.r * intensity,
        g.g * (intensity * 0.95),
        b.b * (intensity * 0.90)
    );

    outputTexture.write(float4(clamp(result, 0.0, 1.0), c.a), gid);
}
