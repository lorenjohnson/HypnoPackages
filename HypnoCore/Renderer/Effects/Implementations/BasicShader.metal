//
//  BasicShader.metal
//  Hypnograph
//
//  Basic image adjustments: contrast, brightness, saturation, hue, invert.
//  All adjustment parameters use -1 to 1 scale (0 = no change).
//

#include <metal_stdlib>
using namespace metal;

// Parameters passed from Swift - must match BasicParamsGPU
struct BasicParams {
    float contrast;      // -1 to 1: 0 = no change, -1 = flat, 1 = high contrast
    float brightness;    // -1 to 1: 0 = no change, -1 = black, 1 = white
    float saturation;    // -1 to 1: 0 = no change, -1 = grayscale, 1 = oversaturated
    float hueShift;      // -1 to 1: rotates hue (-1 = -180°, 0 = no change, 1 = +180°)
    int colorSpace;      // 0=RGB, 1=YUV, 2=HSV, 3=LAB
    int invert;          // 0=false, 1=true
    int textureWidth;
    int textureHeight;
};

// RGB to HSV conversion
float3 rgb2hsv(float3 c) {
    float4 K = float4(0.0, -1.0/3.0, 2.0/3.0, -1.0);
    float4 p = mix(float4(c.bg, K.wz), float4(c.gb, K.xy), step(c.b, c.g));
    float4 q = mix(float4(p.xyw, c.r), float4(c.r, p.yzx), step(p.x, c.r));
    float d = q.x - min(q.w, q.y);
    float e = 1.0e-10;
    return float3(abs(q.z + (q.w - q.y) / (6.0 * d + e)), d / (q.x + e), q.x);
}

// HSV to RGB conversion
float3 hsv2rgb(float3 c) {
    float4 K = float4(1.0, 2.0/3.0, 1.0/3.0, 3.0);
    float3 p = abs(fract(c.xxx + K.xyz) * 6.0 - K.www);
    return c.z * mix(K.xxx, clamp(p - K.xxx, 0.0, 1.0), c.y);
}

// RGB to YUV conversion (BT.601)
float3 rgb2yuv(float3 rgb) {
    float y = 0.299f * rgb.r + 0.587f * rgb.g + 0.114f * rgb.b;
    float u = -0.14713f * rgb.r - 0.28886f * rgb.g + 0.436f * rgb.b + 0.5f;
    float v = 0.615f * rgb.r - 0.51499f * rgb.g - 0.10001f * rgb.b + 0.5f;
    return float3(y, u, v);
}

// YUV to RGB conversion (BT.601)
float3 yuv2rgb(float3 yuv) {
    float y = yuv.x;
    float u = yuv.y - 0.5f;
    float v = yuv.z - 0.5f;
    float r = y + 1.13983f * v;
    float g = y - 0.39465f * u - 0.58060f * v;
    float b = y + 2.03211f * u;
    return float3(r, g, b);
}

// RGB to LAB conversion (approximate)
float3 rgb2lab(float3 rgb) {
    // RGB to XYZ (sRGB D65)
    float3 xyz;
    rgb = mix(rgb / 12.92f, pow((rgb + 0.055f) / 1.055f, 2.4f), step(0.04045f, rgb));
    xyz.x = dot(rgb, float3(0.4124564f, 0.3575761f, 0.1804375f));
    xyz.y = dot(rgb, float3(0.2126729f, 0.7151522f, 0.0721750f));
    xyz.z = dot(rgb, float3(0.0193339f, 0.1191920f, 0.9503041f));

    // XYZ to LAB (D65 white point)
    float3 ref = float3(0.95047f, 1.0f, 1.08883f);
    xyz /= ref;
    xyz = mix(7.787f * xyz + 16.0f/116.0f, pow(xyz, 1.0f/3.0f), step(0.008856f, xyz));

    float L = 116.0f * xyz.y - 16.0f;
    float a = 500.0f * (xyz.x - xyz.y);
    float b = 200.0f * (xyz.y - xyz.z);

    // Normalize to 0-1 range for storage
    return float3(L / 100.0f, (a + 128.0f) / 255.0f, (b + 128.0f) / 255.0f);
}

// LAB to RGB conversion (approximate)
float3 lab2rgb(float3 lab) {
    // Denormalize from 0-1 range
    float L = lab.x * 100.0f;
    float a = lab.y * 255.0f - 128.0f;
    float b = lab.z * 255.0f - 128.0f;

    // LAB to XYZ
    float fy = (L + 16.0f) / 116.0f;
    float fx = a / 500.0f + fy;
    float fz = fy - b / 200.0f;

    float3 xyz;
    xyz.x = mix((fx - 16.0f/116.0f) / 7.787f, fx * fx * fx, step(0.206893f, fx));
    xyz.y = mix((fy - 16.0f/116.0f) / 7.787f, fy * fy * fy, step(0.206893f, fy));
    xyz.z = mix((fz - 16.0f/116.0f) / 7.787f, fz * fz * fz, step(0.206893f, fz));

    // D65 white point
    xyz *= float3(0.95047f, 1.0f, 1.08883f);

    // XYZ to RGB
    float3 rgb;
    rgb.r = dot(xyz, float3(3.2404542f, -1.5371385f, -0.4985314f));
    rgb.g = dot(xyz, float3(-0.9692660f, 1.8760108f, 0.0415560f));
    rgb.b = dot(xyz, float3(0.0556434f, -0.2040259f, 1.0572252f));

    // Linear to sRGB
    rgb = mix(rgb * 12.92f, 1.055f * pow(rgb, 1.0f/2.4f) - 0.055f, step(0.0031308f, rgb));
    return rgb;
}

// MARK: - Basic Adjustment Kernel

kernel void basicKernel(
    texture2d<float, access::sample> inputTexture [[texture(0)]],
    texture2d<float, access::write> outputTexture [[texture(1)]],
    constant BasicParams& params [[buffer(0)]],
    uint2 gid [[thread_position_in_grid]]
) {
    // Bounds check
    if (gid.x >= uint(params.textureWidth) || gid.y >= uint(params.textureHeight)) {
        return;
    }

    // Sample input texture
    constexpr sampler textureSampler(mag_filter::linear, min_filter::linear, address::clamp_to_edge);
    float2 uv = float2(gid) / float2(params.textureWidth, params.textureHeight);
    float4 color = inputTexture.sample(textureSampler, uv);

    float3 rgb = color.rgb;

    // Convert to working color space if needed
    float3 working = rgb;
    if (params.colorSpace == 1) {
        working = rgb2yuv(rgb);
    } else if (params.colorSpace == 2) {
        working = rgb2hsv(rgb);
    } else if (params.colorSpace == 3) {
        working = rgb2lab(rgb);
    }

    // Apply contrast: map -1..1 to 0.5..2.0 multiplier
    // -1 = 0.5x (flat), 0 = 1.0x (no change), 1 = 2.0x (high contrast)
    float contrastMult = 1.0f + params.contrast;  // Maps -1..1 to 0..2
    contrastMult = clamp(contrastMult, 0.5f, 2.0f);
    working = (working - 0.5f) * contrastMult + 0.5f;

    // Apply brightness: map -1..1 to -0.5..0.5 offset
    float brightnessOffset = params.brightness * 0.5f;
    working += brightnessOffset;

    // Apply saturation: mix with luminance (in working space)
    // -1 = grayscale, 0 = no change, 1 = 2x saturation
    float luma = dot(working, float3(0.299f, 0.587f, 0.114f));
    float satMult = 1.0f + params.saturation;  // Maps -1..1 to 0..2
    satMult = clamp(satMult, 0.0f, 2.0f);
    working = mix(float3(luma), working, satMult);

    // Convert back to RGB
    if (params.colorSpace == 1) {
        rgb = yuv2rgb(working);
    } else if (params.colorSpace == 2) {
        rgb = hsv2rgb(working);
    } else if (params.colorSpace == 3) {
        rgb = lab2rgb(working);
    } else {
        rgb = working;
    }

    // Apply hue shift (convert to HSV, rotate hue, convert back)
    if (abs(params.hueShift) > 0.001f) {
        float3 hsv = rgb2hsv(rgb);
        hsv.x = fract(hsv.x + params.hueShift * 0.5f);  // -1..1 maps to -0.5..0.5 rotation
        rgb = hsv2rgb(hsv);
    }

    // Apply invert
    if (params.invert != 0) {
        rgb = 1.0f - rgb;
    }

    // Clamp to valid range
    rgb = clamp(rgb, 0.0f, 1.0f);

    // Write to output (preserve original alpha)
    outputTexture.write(float4(rgb, color.a), gid);
}

