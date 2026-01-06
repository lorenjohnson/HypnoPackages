//
//  ColorEchoShader.metal
//  Hypnograph
//
//  Color echo effect - each RGB channel comes from a different point in time.
//  Red from current frame, green from N frames ago, blue from 2N frames ago.
//  Single-pass implementation for efficiency.
//

#include <metal_stdlib>
using namespace metal;

// Parameters passed from Swift - must match ColorEchoParamsGPU
struct ColorEchoParams {
    float intensity;      // Overall intensity (0.5 - 1.0)
    int textureWidth;
    int textureHeight;
};

// MARK: - Color Echo Kernel
// All textures are BGRA from CVPixelBuffer, same coordinate system
// Creates RGB trails by taking each color channel from a different point in time

kernel void colorEchoKernel(
    texture2d<float, access::read> currentTexture [[texture(0)]],
    texture2d<float, access::read> greenTexture [[texture(1)]],
    texture2d<float, access::read> blueTexture [[texture(2)]],
    texture2d<float, access::write> outputTexture [[texture(3)]],
    constant ColorEchoParams& params [[buffer(0)]],
    uint2 gid [[thread_position_in_grid]]
) {
    int width = params.textureWidth;
    int height = params.textureHeight;

    // Bounds check
    if (gid.x >= uint(width) || gid.y >= uint(height)) {
        return;
    }

    // Direct pixel read
    float4 current = currentTexture.read(gid);
    float4 gFrame = greenTexture.read(gid);
    float4 bFrame = blueTexture.read(gid);

    // Intensity controls the mix between pure channel separation and blended
    // At 1.0: pure R from current, pure G from past, pure B from further past
    // At lower values: blend in some of the other channels for a subtler effect
    float sep = params.intensity;  // separation amount
    float blend = 1.0 - sep;       // blend amount

    // Pure channel extraction
    float rPure = current.r;
    float gPure = gFrame.g;
    float bPure = bFrame.b;

    // Blended: mix in luminance from current frame to maintain brightness
    float currentLuma = dot(current.rgb, float3(0.299, 0.587, 0.114));

    // Final color: separated channels + optional luminance blend
    float r = rPure * sep + currentLuma * blend * 0.5 + current.r * blend * 0.5;
    float g = gPure * sep + currentLuma * blend * 0.5 + current.g * blend * 0.5;
    float b = bPure * sep + currentLuma * blend * 0.5 + current.b * blend * 0.5;

    // Output combined color
    float4 result = float4(r, g, b, 1.0);
    outputTexture.write(result, gid);
}

