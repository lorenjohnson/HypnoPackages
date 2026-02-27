#include <metal_stdlib>
using namespace metal;

struct HypnoParams {
    float wobbleFrequency;
    float wobbleAmplitude;
    float timeSeconds;
    int textureWidth;
    int textureHeight;
};

inline float3 rgb2hsv(float3 c) {
    float4 K = float4(0.0, -1.0 / 3.0, 2.0 / 3.0, -1.0);
    float4 p = mix(float4(c.bg, K.wz), float4(c.gb, K.xy), step(c.b, c.g));
    float4 q = mix(float4(p.xyw, c.r), float4(c.r, p.yzx), step(p.x, c.r));
    float d = q.x - min(q.w, q.y);
    float e = 1.0e-10;
    return float3(abs(q.z + (q.w - q.y) / (6.0 * d + e)), d / (q.x + e), q.x);
}

inline float3 hsv2rgb(float3 c) {
    float4 K = float4(1.0, 2.0 / 3.0, 1.0 / 3.0, 3.0);
    float3 p = abs(fract(c.xxx + K.xyz) * 6.0 - K.www);
    return c.z * mix(K.xxx, clamp(p - K.xxx, 0.0, 1.0), c.y);
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
    float2 uv = (float2(gid) + 0.5) / float2(params.textureWidth, params.textureHeight);
    float4 color = inputTexture.sample(samplerLinear, uv);

    float phase = sin(params.timeSeconds * params.wobbleFrequency);
    float hueDelta = phase * params.wobbleAmplitude;

    float3 hsv = rgb2hsv(color.rgb);
    hsv.x = fract(hsv.x + hueDelta / (2.0 * M_PI_F));
    float3 outRGB = hsv2rgb(hsv);

    outputTexture.write(float4(clamp(outRGB, 0.0, 1.0), color.a), gid);
}
