//
//  BlockFreezeShader.metal
//  Hypnograph
//
//  Simple block-based freeze effect.
//  Blocks randomly freeze in place while others update normally.
//  Creates a temporal mosaic effect with minimal parameters.
//

#include <metal_stdlib>
using namespace metal;

struct BlockFreezeParams {
    int textureWidth;
    int textureHeight;
    int blockSize;          // Size of freeze blocks (8-64)
    float freezeChance;     // Per-block probability of being frozen (0-1)
    float streakChance;     // Chance a frozen block will streak instead (0-1)
    uint randomSeed;
};

// Simple hash for per-block randomness
inline uint blockHash(uint2 blockCoord, uint seed) {
    uint h = blockCoord.x * 374761393u + blockCoord.y * 668265263u + seed;
    h = (h ^ (h >> 13)) * 1274126177u;
    return h ^ (h >> 16);
}

kernel void blockFreezeKernel(
    texture2d<float, access::read> currentTexture [[texture(0)]],
    texture2d<float, access::read> historyTexture [[texture(1)]],
    texture2d<float, access::write> outputTexture [[texture(2)]],
    constant BlockFreezeParams& params [[buffer(0)]],
    uint2 gid [[thread_position_in_grid]]
) {
    int width = params.textureWidth;
    int height = params.textureHeight;
    
    if (gid.x >= uint(width) || gid.y >= uint(height)) {
        return;
    }
    
    // Determine which block this pixel belongs to
    int blockSize = max(params.blockSize, 4);
    uint2 blockCoord = uint2(gid.x / blockSize, gid.y / blockSize);
    
    // Get per-block random value (stable for this frame)
    uint hash = blockHash(blockCoord, params.randomSeed);
    float blockRand = float(hash & 0xFFFFu) / 65535.0;
    
    // Read current and history pixels
    float4 current = currentTexture.read(gid);
    float4 history = historyTexture.read(gid);
    
    float4 result;
    
    if (blockRand < params.freezeChance) {
        // This block is frozen - use history
        
        // Check if this frozen block should streak
        float streakRand = float((hash >> 16) & 0xFFFFu) / 65535.0;
        
        if (streakRand < params.streakChance) {
            // Streak: blend history with slight directional offset
            float streakDir = float((hash >> 8) & 0xFF) / 255.0 * 6.28318; // Random angle
            float streakDist = 2.0 + float(hash & 0x7) * 0.5;
            
            int2 offsetCoord = int2(gid) + int2(cos(streakDir) * streakDist, sin(streakDir) * streakDist);
            offsetCoord = clamp(offsetCoord, int2(0), int2(width - 1, height - 1));
            
            float4 streakSample = historyTexture.read(uint2(offsetCoord));
            result = mix(history, streakSample, 0.5);
        } else {
            // Pure freeze
            result = history;
        }
    } else {
        // This block updates normally
        result = current;
    }
    
    outputTexture.write(result, gid);
}

