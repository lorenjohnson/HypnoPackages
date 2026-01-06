//
//  GaussianBlurShader.metal
//  Hypnograph
//
//  Gaussian blur using separable two-pass convolution for efficiency.
//  First pass blurs horizontally, second pass blurs vertically.
//

#include <metal_stdlib>
using namespace metal;

// Parameters passed from Swift - must match GaussianBlurParamsGPU
struct GaussianBlurParams {
    float radius;        // Blur radius in pixels
    int textureWidth;
    int textureHeight;
    int isVerticalPass;  // 0 = horizontal, 1 = vertical
};

// Gaussian weight calculation
inline float gaussianWeight(float x, float sigma) {
    float coefficient = 1.0 / (sqrt(2.0 * M_PI_F) * sigma);
    float exponent = -(x * x) / (2.0 * sigma * sigma);
    return coefficient * exp(exponent);
}

// MARK: - Gaussian Blur Kernel (Single Pass - Separable)

kernel void gaussianBlurKernel(
    texture2d<float, access::sample> inputTexture [[texture(0)]],
    texture2d<float, access::write> outputTexture [[texture(1)]],
    constant GaussianBlurParams& params [[buffer(0)]],
    uint2 gid [[thread_position_in_grid]]
) {
    // Bounds check
    if (gid.x >= uint(params.textureWidth) || gid.y >= uint(params.textureHeight)) {
        return;
    }

    float radius = max(0.0, params.radius);
    
    // No blur if radius is essentially zero
    if (radius < 0.5) {
        constexpr sampler textureSampler(mag_filter::linear, min_filter::linear, address::clamp_to_edge);
        float2 uv = (float2(gid) + 0.5) / float2(params.textureWidth, params.textureHeight);
        float4 color = inputTexture.sample(textureSampler, uv);
        outputTexture.write(color, gid);
        return;
    }

    // Sigma is approximately radius / 3 for a good gaussian falloff
    float sigma = radius / 3.0;
    int kernelRadius = int(ceil(radius));
    
    constexpr sampler textureSampler(mag_filter::linear, min_filter::linear, address::clamp_to_edge);
    
    float4 colorSum = float4(0.0);
    float weightSum = 0.0;
    
    float2 texelSize = 1.0 / float2(params.textureWidth, params.textureHeight);
    float2 centerUV = (float2(gid) + 0.5) * texelSize;
    
    // Direction based on pass
    float2 direction = params.isVerticalPass ? float2(0.0, 1.0) : float2(1.0, 0.0);
    
    // Sample along the blur direction
    for (int i = -kernelRadius; i <= kernelRadius; i++) {
        float weight = gaussianWeight(float(i), sigma);
        float2 offset = direction * float(i) * texelSize;
        float2 sampleUV = centerUV + offset;
        
        float4 sampleColor = inputTexture.sample(textureSampler, sampleUV);
        colorSum += sampleColor * weight;
        weightSum += weight;
    }
    
    // Normalize and write result
    float4 result = colorSum / weightSum;
    outputTexture.write(result, gid);
}

