#include <metal_stdlib>
using namespace metal;

struct HypnoParams {
    float contrast;
    float brightness;
    float saturation;
    float hueShift;
    int colorSpace;
    int outputColorMode;
    bool invert;
    int textureWidth;
    int textureHeight;
};

float3 rgb2hsv(float3 c) {
    float4 K = float4(0.0, -1.0/3.0, 2.0/3.0, -1.0);
    float4 p = mix(float4(c.bg, K.wz), float4(c.gb, K.xy), step(c.b, c.g));
    float4 q = mix(float4(p.xyw, c.r), float4(c.r, p.yzx), step(p.x, c.r));
    float d = q.x - min(q.w, q.y);
    float e = 1.0e-10;
    return float3(abs(q.z + (q.w - q.y) / (6.0 * d + e)), d / (q.x + e), q.x);
}

float3 hsv2rgb(float3 c) {
    float4 K = float4(1.0, 2.0/3.0, 1.0/3.0, 3.0);
    float3 p = abs(fract(c.xxx + K.xyz) * 6.0 - K.www);
    return c.z * mix(K.xxx, clamp(p - K.xxx, 0.0, 1.0), c.y);
}

float3 rgb2yuv(float3 rgb) {
    float y = 0.299f * rgb.r + 0.587f * rgb.g + 0.114f * rgb.b;
    float u = -0.14713f * rgb.r - 0.28886f * rgb.g + 0.436f * rgb.b + 0.5f;
    float v = 0.615f * rgb.r - 0.51499f * rgb.g - 0.10001f * rgb.b + 0.5f;
    return float3(y, u, v);
}

float3 yuv2rgb(float3 yuv) {
    float y = yuv.x;
    float u = yuv.y - 0.5f;
    float v = yuv.z - 0.5f;
    float r = y + 1.13983f * v;
    float g = y - 0.39465f * u - 0.58060f * v;
    float b = y + 2.03211f * u;
    return float3(r, g, b);
}

float3 rgb2lab(float3 rgb) {
    float3 xyz;
    rgb = mix(rgb / 12.92f, pow((rgb + 0.055f) / 1.055f, 2.4f), step(0.04045f, rgb));
    xyz.x = dot(rgb, float3(0.4124564f, 0.3575761f, 0.1804375f));
    xyz.y = dot(rgb, float3(0.2126729f, 0.7151522f, 0.0721750f));
    xyz.z = dot(rgb, float3(0.0193339f, 0.1191920f, 0.9503041f));

    float3 ref = float3(0.95047f, 1.0f, 1.08883f);
    xyz /= ref;
    xyz = mix(7.787f * xyz + 16.0f/116.0f, pow(xyz, 1.0f/3.0f), step(0.008856f, xyz));

    float L = 116.0f * xyz.y - 16.0f;
    float a = 500.0f * (xyz.x - xyz.y);
    float b = 200.0f * (xyz.y - xyz.z);

    return float3(L / 100.0f, (a + 128.0f) / 255.0f, (b + 128.0f) / 255.0f);
}

float3 lab2rgb(float3 lab) {
    float L = lab.x * 100.0f;
    float a = lab.y * 255.0f - 128.0f;
    float b = lab.z * 255.0f - 128.0f;

    float fy = (L + 16.0f) / 116.0f;
    float fx = a / 500.0f + fy;
    float fz = fy - b / 200.0f;

    float3 xyz;
    xyz.x = mix((fx - 16.0f/116.0f) / 7.787f, fx * fx * fx, step(0.206893f, fx));
    xyz.y = mix((fy - 16.0f/116.0f) / 7.787f, fy * fy * fy, step(0.206893f, fy));
    xyz.z = mix((fz - 16.0f/116.0f) / 7.787f, fz * fz * fz, step(0.206893f, fz));

    xyz *= float3(0.95047f, 1.0f, 1.08883f);

    float3 rgb;
    rgb.r = dot(xyz, float3(3.2404542f, -1.5371385f, -0.4985314f));
    rgb.g = dot(xyz, float3(-0.9692660f, 1.8760108f, 0.0415560f));
    rgb.b = dot(xyz, float3(0.0556434f, -0.2040259f, 1.0572252f));

    rgb = mix(rgb * 12.92f, 1.055f * pow(rgb, 1.0f/2.4f) - 0.055f, step(0.0031308f, rgb));
    return rgb;
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

    constexpr sampler textureSampler(mag_filter::linear, min_filter::linear, address::clamp_to_edge);
    float2 uv = float2(gid) / float2(params.textureWidth, params.textureHeight);
    float4 color = inputTexture.sample(textureSampler, uv);

    float3 rgb = color.rgb;

    float3 working = rgb;
    if (params.colorSpace == 1) {
        working = rgb2yuv(rgb);
    } else if (params.colorSpace == 2) {
        working = rgb2hsv(rgb);
    } else if (params.colorSpace == 3) {
        working = rgb2lab(rgb);
    }

    float contrastMult = clamp(1.0f + params.contrast, 0.5f, 2.0f);
    working = (working - 0.5f) * contrastMult + 0.5f;

    float brightnessOffset = params.brightness * 0.5f;
    working += brightnessOffset;

    float luma = dot(working, float3(0.299f, 0.587f, 0.114f));
    float satMult = clamp(1.0f + params.saturation, 0.0f, 2.0f);
    working = mix(float3(luma), working, satMult);

    if (params.colorSpace == 1) {
        rgb = yuv2rgb(working);
    } else if (params.colorSpace == 2) {
        rgb = hsv2rgb(working);
    } else if (params.colorSpace == 3) {
        rgb = lab2rgb(working);
    } else {
        rgb = working;
    }

    if (abs(params.hueShift) > 0.001f) {
        float3 hsv = rgb2hsv(rgb);
        hsv.x = fract(hsv.x + params.hueShift * 0.5f);
        rgb = hsv2rgb(hsv);
    }

    if (params.invert) {
        rgb = 1.0f - rgb;
    }

    rgb = clamp(rgb, 0.0f, 1.0f);

    float3 outputColor = rgb;
    if (params.outputColorMode == 1) {
        outputColor = rgb2yuv(rgb);
    } else if (params.outputColorMode == 2) {
        outputColor = rgb2hsv(rgb);
    } else if (params.outputColorMode == 3) {
        outputColor = rgb2lab(rgb);
    }

    outputColor = clamp(outputColor, 0.0f, 1.0f);
    outputTexture.write(float4(outputColor, color.a), gid);
}
