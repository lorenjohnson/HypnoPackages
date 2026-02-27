#include <metal_stdlib>
using namespace metal;

struct HypnoParams {
    float levels;
    float decayAmount;
    int textureWidth;
    int textureHeight;
};

inline float3 posterize(float3 rgb, float levels) {
    float safeLevels = max(levels, 2.0);
    float steps = max(safeLevels - 1.0, 1.0);
    return floor(clamp(rgb, 0.0, 1.0) * steps + 0.5) / steps;
}

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
    float4 previous = previousTexture.sample(samplerLinear, uv);

    float3 currentPoster = posterize(current.rgb, params.levels);
    float3 previousPoster = posterize(previous.rgb, params.levels);

    float3 darkened = min(currentPoster, previousPoster);
    float decay = clamp(params.decayAmount, 0.0, 1.0);
    float3 mixed = mix(currentPoster, darkened, decay);

    outputTexture.write(float4(clamp(mixed, 0.0, 1.0), current.a), gid);
}
