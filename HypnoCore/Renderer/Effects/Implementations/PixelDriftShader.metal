//
//  PixelDriftShader.metal
//  Hypnograph
//
//  Pixel drift effect - pixels "smear" in direction of motion.
//  Creates organic streaking trails where movement occurs.
//  Stationary areas remain clean.
//

#include <metal_stdlib>
using namespace metal;

struct PixelDriftParams {
    int textureWidth;
    int textureHeight;
    float driftStrength;    // How far pixels can drift (1-20)
    float threshold;        // Motion threshold to trigger drift (0-1)
    float decay;            // How much old drift fades (0-1)
    uint randomSeed;
};

kernel void pixelDriftKernel(
    texture2d<float, access::read> currentTexture [[texture(0)]],
    texture2d<float, access::read> previousTexture [[texture(1)]],
    texture2d<float, access::read> feedbackTexture [[texture(2)]],
    texture2d<float, access::write> outputTexture [[texture(3)]],
    constant PixelDriftParams& params [[buffer(0)]],
    uint2 gid [[thread_position_in_grid]]
) {
    int width = params.textureWidth;
    int height = params.textureHeight;
    
    if (gid.x >= uint(width) || gid.y >= uint(height)) {
        return;
    }
    
    float4 current = currentTexture.read(gid);
    float4 previous = previousTexture.read(gid);
    float4 feedback = feedbackTexture.read(gid);
    
    // Calculate motion (difference between frames)
    float3 diff = abs(current.rgb - previous.rgb);
    float motion = (diff.r + diff.g + diff.b) / 3.0;
    
    float4 result;
    
    if (motion > params.threshold) {
        // Motion detected - this pixel drifts
        // Calculate drift direction from gradient
        
        // Sample neighbors to find motion direction
        int2 pos = int2(gid);
        float4 left = currentTexture.read(uint2(max(0, pos.x - 1), pos.y));
        float4 right = currentTexture.read(uint2(min(width - 1, pos.x + 1), pos.y));
        float4 up = currentTexture.read(uint2(pos.x, max(0, pos.y - 1)));
        float4 down = currentTexture.read(uint2(pos.x, min(height - 1, pos.y + 1)));
        
        // Gradient gives us drift direction
        float dx = dot(right.rgb - left.rgb, float3(1.0)) / 3.0;
        float dy = dot(down.rgb - up.rgb, float3(1.0)) / 3.0;
        
        // Normalize and scale by drift strength
        float len = length(float2(dx, dy));
        if (len > 0.01) {
            float2 driftDir = float2(dx, dy) / len;
            float driftDist = params.driftStrength * motion;
            
            // Sample from offset position (creates smear trail)
            int2 sourcePos = pos - int2(driftDir * driftDist);
            sourcePos = clamp(sourcePos, int2(0), int2(width - 1, height - 1));
            
            float4 driftSample = currentTexture.read(uint2(sourcePos));
            
            // Blend with feedback for trail persistence
            result = mix(driftSample, feedback, params.decay * 0.5);
        } else {
            // No clear direction - blend current with feedback
            result = mix(current, feedback, params.decay * 0.3);
        }
    } else {
        // No motion - mostly show current, slight feedback persistence
        result = mix(current, feedback, params.decay * 0.1);
    }
    
    outputTexture.write(result, gid);
}

