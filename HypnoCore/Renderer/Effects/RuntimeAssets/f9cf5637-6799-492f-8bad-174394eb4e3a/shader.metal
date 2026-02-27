#include <metal_stdlib>
using namespace metal;

struct HypnoParams {
    float sensitivity;
    float intensity;
    float originalBlend;
    int textureWidth;
    int textureHeight;
};

kernel void render(
    texture2d<float, access::sample> currentTexture [[texture(0)]],
    texture2d<float, access::sample> previousTexture [[texture(1)]],
    texture2d<float, access::write> outputTexture [[texture(2)]],
    constant HypnoParams& params [[buffer(0)]],
    uint2 gid [[thread_position_in_grid]]
) {
    if (gid.x >= uint(params.textureWidth) || gid.y >= uint(params.textureHeight)) {
        return;
    }

    constexpr sampler samplerLinear(mag_filter::linear, min_filter::linear, address::clamp_to_edge);
    float2 uv = (float2(gid) + 0.5) / float2(params.textureWidth, params.textureHeight);

    float4 current = currentTexture.sample(samplerLinear, uv);
    float4 prev = previousTexture.sample(samplerLinear, uv);

    float3 diff = abs(current.rgb - prev.rgb);
    float threshold = clamp(params.sensitivity * 0.5, 0.0, 0.5);
    diff = max(diff - float3(threshold), 0.0);
    diff = clamp(diff * max(params.intensity, 0.0), 0.0, 1.0);

    float blend = clamp(params.originalBlend, 0.0, 1.0);
    float3 result = mix(diff, current.rgb, blend);
    outputTexture.write(float4(result, current.a), gid);
}
