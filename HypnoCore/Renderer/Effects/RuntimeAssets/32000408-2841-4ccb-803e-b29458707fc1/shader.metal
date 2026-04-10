#include <metal_stdlib>
using namespace metal;

struct HypnoParams {
    int jumpFrames;
    int frameIndex;
    int textureWidth;
    int textureHeight;
};

inline float4 sampleSourceByIndex(
    int sourceIndex,
    float2 uv,
    texture2d<float, access::sample> currentTexture,
    texture2d<float, access::sample> historyA,
    texture2d<float, access::sample> historyB,
    texture2d<float, access::sample> historyC
) {
    constexpr sampler samplerLinear(mag_filter::linear, min_filter::linear, address::clamp_to_edge);
    switch (sourceIndex) {
        case 1: return historyA.sample(samplerLinear, uv);
        case 2: return historyB.sample(samplerLinear, uv);
        case 3: return historyC.sample(samplerLinear, uv);
        default: return currentTexture.sample(samplerLinear, uv);
    }
}

kernel void render(
    texture2d<float, access::sample> currentTexture [[texture(0)]],
    texture2d<float, access::sample> historyA [[texture(1)]],
    texture2d<float, access::sample> historyB [[texture(2)]],
    texture2d<float, access::sample> historyC [[texture(3)]],
    texture2d<float, access::write> outputTexture [[texture(4)]],
    constant HypnoParams& params [[buffer(0)]],
    uint2 gid [[thread_position_in_grid]]
) {
    if (gid.x >= uint(params.textureWidth) || gid.y >= uint(params.textureHeight)) {
        return;
    }

    float2 texSize = float2(params.textureWidth, params.textureHeight);
    float2 uv = (float2(gid) + 0.5) / texSize;

    int jumpFrames = max(params.jumpFrames, 1);
    int segmentIndex = params.frameIndex / jumpFrames;
    int sourceIndex = segmentIndex % 4;

    float4 output = sampleSourceByIndex(
        sourceIndex,
        uv,
        currentTexture,
        historyA,
        historyB,
        historyC
    );

    outputTexture.write(output, gid);
}
