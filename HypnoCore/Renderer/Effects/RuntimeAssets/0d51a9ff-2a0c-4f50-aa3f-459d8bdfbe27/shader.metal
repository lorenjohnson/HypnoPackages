#include <metal_stdlib>
using namespace metal;

struct HypnoParams {
    float intensity;
    int textureWidth;
    int textureHeight;
};

inline float luminance(float3 color) {
    return dot(color, float3(0.2126, 0.7152, 0.0722));
}

inline float3 softContrast(float3 color, float contrast) {
    return clamp((color - 0.5) * contrast + 0.5, 0.0, 1.0);
}

inline float hash12(float2 p) {
    float3 p3 = fract(float3(p.xyx) * 0.1031);
    p3 += dot(p3, p3.yzx + 33.33);
    return fract((p3.x + p3.y) * p3.z);
}

inline float4 sampleTexture(
    texture2d<float, access::sample> texture,
    float2 uv
) {
    constexpr sampler samplerLinear(mag_filter::linear, min_filter::linear, address::clamp_to_edge);
    return texture.sample(samplerLinear, uv);
}

inline float3 diffuseBlur(
    texture2d<float, access::sample> texture,
    float2 uv,
    float2 texel,
    float radius
) {
    float2 offsets[8] = {
        float2(-1.0,  0.0),
        float2( 1.0,  0.0),
        float2( 0.0, -1.0),
        float2( 0.0,  1.0),
        float2(-0.7, -0.7),
        float2( 0.7, -0.7),
        float2(-0.7,  0.7),
        float2( 0.7,  0.7)
    };

    float3 accum = sampleTexture(texture, uv).rgb * 2.0;
    float total = 2.0;

    for (uint i = 0; i < 8; ++i) {
        float2 sampleUV = uv + offsets[i] * texel * radius;
        float weight = (i < 4) ? 1.0 : 0.75;
        accum += sampleTexture(texture, sampleUV).rgb * weight;
        total += weight;
    }

    return accum / max(total, 0.0001);
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

    float amount = clamp(params.intensity, 0.0, 1.0);
    float2 texSize = float2(params.textureWidth, params.textureHeight);
    float2 uv = (float2(gid) + 0.5) / texSize;
    float2 texel = 1.0 / max(texSize, float2(1.0));

    float4 sampled = sampleTexture(inputTexture, uv);
    float3 base = sampled.rgb;
    float baseLuma = luminance(base);

    float blurRadius = mix(1.0, 6.0, amount);
    float3 blurred = diffuseBlur(inputTexture, uv, texel, blurRadius);

    float highlightMask = smoothstep(0.42, 0.90, baseLuma);
    float shadowMask = 1.0 - smoothstep(0.16, 0.52, baseLuma);

    float glowLuma = smoothstep(0.25, 0.85, luminance(blurred));
    float3 warmGlow = blurred * float3(1.16, 1.02, 0.82);
    float3 glowed = mix(
        base,
        base + warmGlow * (0.30 + 0.52 * amount),
        clamp(highlightMask * (0.42 + 0.52 * amount) + glowLuma * 0.18, 0.0, 1.0)
    );

    float3 toned = glowed;
    toned *= mix(float3(1.0), float3(0.89, 1.00, 1.11), shadowMask * (0.22 + 0.18 * amount));
    toned *= mix(float3(1.0), float3(1.10, 1.01, 0.87), highlightMask * (0.18 + 0.16 * amount));

    float3 matte = toned * (0.90 - 0.03 * amount) + float3(0.035 + 0.02 * amount);
    float3 softened = softContrast(matte, mix(1.0, 0.90, amount));
    float3 desaturated = mix(float3(luminance(softened)), softened, 0.97 - 0.06 * amount);

    float vignetteDistance = distance(uv, float2(0.5, 0.5));
    float vignette = smoothstep(0.38, 0.84, vignetteDistance);
    float3 vignetted = desaturated * (1.0 - vignette * (0.14 + 0.18 * amount));

    float noiseA = hash12(float2(gid) + 17.0);
    float noiseB = hash12(float2(gid.y, gid.x) + 41.0);
    float grain = ((noiseA + noiseB) * 0.5 - 0.5) * (0.040 + 0.030 * amount);
    float3 grained = vignetted + float3(grain);

    outputTexture.write(float4(clamp(grained, 0.0, 1.0), sampled.a), gid);
}
