#include <metal_stdlib>
using namespace metal;

struct HypnoParams {
    int holdFrames;
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
    texture2d<float, access::sample> historyC,
    texture2d<float, access::sample> historyD
) {
    constexpr sampler samplerLinear(mag_filter::linear, min_filter::linear, address::clamp_to_edge);
    switch (sourceIndex) {
        case 1: return historyA.sample(samplerLinear, uv);
        case 2: return historyB.sample(samplerLinear, uv);
        case 3: return historyC.sample(samplerLinear, uv);
        case 4: return historyD.sample(samplerLinear, uv);
        default: return currentTexture.sample(samplerLinear, uv);
    }
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

    int holdFrames = max(params.holdFrames, 1);
    int segmentIndex = params.frameIndex / holdFrames;
    int baseIndex = segmentIndex % 5;
    float4 result = sampleSourceByIndex(
        baseIndex,
        uv,
        currentTexture,
        historyA,
        historyB,
        historyC,
        historyD
    );
    outputTexture.write(result, gid);
}
