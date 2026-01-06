//
//  PixelateShader.metal
//  Hypnograph
//
//  Simple Metal compute shader that pixelates an image.
//  Demonstrates basic Metal shader pattern for effect hooks.
//

#include <metal_stdlib>
using namespace metal;

// Parameters passed from Swift
struct PixelateParams {
    int blockSize;      // Size of each pixel block (e.g., 8 = 8x8 blocks)
    int textureWidth;
    int textureHeight;
};

// MARK: - Pixelate Kernel

kernel void pixelateKernel(
    texture2d<float, access::sample> inputTexture [[texture(0)]],
    texture2d<float, access::write> outputTexture [[texture(1)]],
    constant PixelateParams& params [[buffer(0)]],
    uint2 gid [[thread_position_in_grid]]
) {
    // Bounds check
    if (gid.x >= uint(params.textureWidth) || gid.y >= uint(params.textureHeight)) {
        return;
    }
    
    int blockSize = max(1, params.blockSize);
    
    // Find the top-left corner of this pixel's block
    int blockX = (int(gid.x) / blockSize) * blockSize;
    int blockY = (int(gid.y) / blockSize) * blockSize;
    
    // Sample from center of block for the block's color
    float2 centerUV = float2(
        float(blockX) + float(blockSize) * 0.5,
        float(blockY) + float(blockSize) * 0.5
    );
    
    // Normalize to 0-1 range for sampling
    float2 normalizedUV = centerUV / float2(params.textureWidth, params.textureHeight);
    
    // Clamp to valid range
    normalizedUV = clamp(normalizedUV, float2(0.0), float2(1.0));
    
    // Sample with linear filtering
    constexpr sampler textureSampler(mag_filter::linear, min_filter::linear, address::clamp_to_edge);
    float4 color = inputTexture.sample(textureSampler, normalizedUV);
    
    // Write to output
    outputTexture.write(color, gid);
}

