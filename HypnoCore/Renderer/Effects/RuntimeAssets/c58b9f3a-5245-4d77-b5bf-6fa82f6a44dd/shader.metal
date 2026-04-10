#include <metal_stdlib>
using namespace metal;

struct HypnoParams {
    int holdLength;
    int historySpan;
    bool avoidRepeats;
    float mixAmount;
    int frameIndex;
    int textureWidth;
    int textureHeight;
};

inline float hash11(float x) {
    return fract(sin(x * 127.1) * 43758.5453123);
}

inline int selectSourceIndex(float chooser) {
    if (chooser > 0.85) {
        return 3;
    } else if (chooser > 0.60) {
        return 2;
    } else if (chooser > 0.30) {
        return 1;
    }
    return 0;
}

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

    constexpr sampler samplerLinear(mag_filter::linear, min_filter::linear, address::clamp_to_edge);

    float2 texSize = float2(params.textureWidth, params.textureHeight);
    float2 uv = (float2(gid) + 0.5) / texSize;

    float4 current = currentTexture.sample(samplerLinear, uv);

    int holdLength = max(params.holdLength, 1);
    float segmentIndex = floor(float(params.frameIndex) / float(holdLength));
    int sourceIndex = selectSourceIndex(hash11(segmentIndex));

    if (params.avoidRepeats && segmentIndex > 0.0) {
        int previousIndex = selectSourceIndex(hash11(segmentIndex - 1.0));
        if (sourceIndex == previousIndex) {
            int alternateIndex = selectSourceIndex(hash11(segmentIndex * 19.31 + 7.13));
            if (alternateIndex == previousIndex) {
                alternateIndex = (previousIndex + 1) % 4;
            }
            sourceIndex = alternateIndex;
        }
    }

    float4 swapped = sampleSourceByIndex(
        sourceIndex,
        uv,
        currentTexture,
        historyA,
        historyB,
        historyC
    );

    float mixAmount = clamp(params.mixAmount, 0.0, 1.0);
    float3 result = mix(current.rgb, swapped.rgb, mixAmount);

    outputTexture.write(float4(clamp(result, 0.0, 1.0), current.a), gid);
}
