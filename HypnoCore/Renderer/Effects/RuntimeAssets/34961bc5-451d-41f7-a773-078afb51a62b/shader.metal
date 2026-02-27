#include <metal_stdlib>
using namespace metal;

struct HypnoParams {
    float radius;
    int textureWidth;
    int textureHeight;
};

inline float gaussianWeight(float x, float sigma) {
    float coefficient = 1.0 / (sqrt(2.0 * M_PI_F) * sigma);
    float exponent = -(x * x) / (2.0 * sigma * sigma);
    return coefficient * exp(exponent);
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

    float radius = max(0.0, params.radius);
    constexpr sampler textureSampler(mag_filter::linear, min_filter::linear, address::clamp_to_edge);
    float2 texel = 1.0 / float2(params.textureWidth, params.textureHeight);
    float2 uv = (float2(gid) + 0.5) * texel;

    if (radius < 0.5) {
        outputTexture.write(inputTexture.sample(textureSampler, uv), gid);
        return;
    }

    float sigma = max(radius / 3.0, 0.2);
    int kernelRadius = min(int(ceil(radius)), 32);

    float4 center = inputTexture.sample(textureSampler, uv);
    float centerW = gaussianWeight(0.0, sigma);

    float4 colorSum = center * centerW;
    float weightSum = centerW;

    for (int i = 1; i <= kernelRadius; i++) {
        float w = gaussianWeight(float(i), sigma);
        float2 dx = float2(float(i) * texel.x, 0.0);
        float2 dy = float2(0.0, float(i) * texel.y);

        colorSum += inputTexture.sample(textureSampler, uv - dx) * w;
        colorSum += inputTexture.sample(textureSampler, uv + dx) * w;
        colorSum += inputTexture.sample(textureSampler, uv - dy) * w;
        colorSum += inputTexture.sample(textureSampler, uv + dy) * w;
        weightSum += 4.0 * w;
    }

    outputTexture.write(colorSum / max(weightSum, 1e-6), gid);
}
