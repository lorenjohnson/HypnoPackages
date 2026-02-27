#include <metal_stdlib>
using namespace metal;

struct HypnoParams {
    float quality;
    int iframeInterval;
    float stickiness;
    float glitch;
    float diffThreshold;
    int frameIndex;
    int textureWidth;
    int textureHeight;
};

inline float hash(float2 p) {
    return fract(sin(dot(p, float2(127.1, 311.7))) * 43758.5453);
}

kernel void render(
    texture2d<float, access::sample> currentTexture [[texture(0)]],
    texture2d<float, access::sample> referenceTexture [[texture(1)]],
    texture2d<float, access::write> outputTexture [[texture(2)]],
    constant HypnoParams& params [[buffer(0)]],
    uint2 gid [[thread_position_in_grid]]
) {
    if (gid.x >= uint(params.textureWidth) || gid.y >= uint(params.textureHeight)) {
        return;
    }

    constexpr sampler texSampler(mag_filter::linear, min_filter::linear, address::clamp_to_edge);
    float2 texSize = float2(params.textureWidth, params.textureHeight);
    float2 uv = (float2(gid) + 0.5) / texSize;

    float4 current = currentTexture.sample(texSampler, uv);
    float4 reference = referenceTexture.sample(texSampler, uv);

    int interval = max(params.iframeInterval, 1);
    bool isIFrame = (params.frameIndex % interval) == 0;

    float3 diff = abs(current.rgb - reference.rgb);
    float motion = (diff.r + diff.g + diff.b) / 3.0;
    bool localReset = isIFrame || (motion > params.diffThreshold);

    if (localReset) {
        outputTexture.write(current, gid);
        return;
    }

    float baseBlend = 1.0 - params.stickiness;
    float motionStick = motion * params.glitch * 2.0;
    float blend = baseBlend * (1.0 - clamp(motionStick, 0.0, 0.95));

    float3 blended = mix(reference.rgb, current.rgb, blend);

    if (params.glitch > 0.3 && motion > 0.05) {
        float2 px = 1.0 / texSize;
        float4 refL = referenceTexture.sample(texSampler, clamp(uv + float2(-2.0 * px.x, 0.0), float2(0.0), float2(1.0)));
        float4 refR = referenceTexture.sample(texSampler, clamp(uv + float2(2.0 * px.x, 0.0), float2(0.0), float2(1.0)));
        float4 refU = referenceTexture.sample(texSampler, clamp(uv + float2(0.0, -2.0 * px.y), float2(0.0), float2(1.0)));
        float4 refD = referenceTexture.sample(texSampler, clamp(uv + float2(0.0, 2.0 * px.y), float2(0.0), float2(1.0)));

        float2 gradient = float2(
            dot(refR.rgb - refL.rgb, float3(1.0)),
            dot(refD.rgb - refU.rgb, float3(1.0))
        );

        float smearAmount = params.glitch * motion * 0.5;
        float2 smearOffset = normalize(gradient + 0.001) * smearAmount * 0.02;
        float2 smearUV = clamp(uv + smearOffset, float2(0.0), float2(1.0));
        float4 smeared = referenceTexture.sample(texSampler, smearUV);
        blended = mix(blended, smeared.rgb, smearAmount);
    }

    if (params.quality < 0.9) {
        float levels = max(4.0, params.quality * params.quality * 256.0);
        float dither = (hash(float2(gid) + float(params.frameIndex) * 0.1) - 0.5) / levels;
        blended = floor((blended + dither) * levels + 0.5) / levels;
    }

    outputTexture.write(float4(clamp(blended, 0.0, 1.0), current.a), gid);
}
