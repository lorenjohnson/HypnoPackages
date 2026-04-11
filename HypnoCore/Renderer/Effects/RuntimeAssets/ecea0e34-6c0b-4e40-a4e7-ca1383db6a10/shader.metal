#include <metal_stdlib>
using namespace metal;

struct HypnoParams {
    float bleedPixels;
    float chromaSoftness;
    float chromaPhase;
    int frameIndex;
    int textureWidth;
    int textureHeight;
};

inline float3 rgbToYiq(float3 rgb) {
    float y = dot(rgb, float3(0.299, 0.587, 0.114));
    float i = dot(rgb, float3(0.596, -0.274, -0.322));
    float q = dot(rgb, float3(0.211, -0.523, 0.312));
    return float3(y, i, q);
}

inline float3 yiqToRgb(float3 yiq) {
    float r = dot(yiq, float3(1.000, 0.956, 0.621));
    float g = dot(yiq, float3(1.000, -0.272, -0.647));
    float b = dot(yiq, float3(1.000, -1.106, 1.703));
    return float3(r, g, b);
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

    constexpr sampler s(mag_filter::linear, min_filter::linear, address::clamp_to_edge);
    float2 texSize = float2(params.textureWidth, params.textureHeight);
    float2 texel = 1.0 / max(texSize, float2(1.0));
    float2 uv = (float2(gid) + 0.5) * texel;

    float px = max(params.bleedPixels, 0.0);
    float2 dx = float2(px * texel.x, 0.0);
    float soft = clamp(params.chromaSoftness, 0.0, 1.0);

    float3 yiqC = rgbToYiq(inputTexture.sample(s, uv).rgb);
    float3 yiqL1 = rgbToYiq(inputTexture.sample(s, clamp(uv - dx, float2(0.0), float2(1.0))).rgb);
    float3 yiqL2 = rgbToYiq(inputTexture.sample(s, clamp(uv - dx * 2.0, float2(0.0), float2(1.0))).rgb);
    float3 yiqR1 = rgbToYiq(inputTexture.sample(s, clamp(uv + dx, float2(0.0), float2(1.0))).rgb);

    // Keep luma mostly intact; degrade chroma with directional bleed.
    float y = yiqC.x;
    float i = yiqC.y * (1.0 - 0.6 * soft)
        + yiqL1.y * (0.45 * soft)
        + yiqL2.y * (0.22 * soft)
        + yiqR1.y * (0.10 * soft);
    float q = yiqC.z * (1.0 - 0.65 * soft)
        + yiqL1.z * (0.40 * soft)
        + yiqL2.z * (0.25 * soft)
        + yiqR1.z * (0.08 * soft);

    // Small scanline-time phase wobble in the I/Q plane.
    float line = float(gid.y);
    float t = float(params.frameIndex) * 0.0166667;
    float phase = params.chromaPhase * 0.25 * sin(line * 0.09 + t * 2.7);
    float cs = cos(phase);
    float sn = sin(phase);
    float i2 = i * cs - q * sn;
    float q2 = i * sn + q * cs;

    float3 rgb = yiqToRgb(float3(y, i2, q2));
    float a = inputTexture.sample(s, uv).a;
    outputTexture.write(float4(clamp(rgb, 0.0, 1.0), a), gid);
}
