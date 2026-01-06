//
//  GlitchBlocksShader.metal
//  Hypnograph
//
//  Glitch blocks effect - destructive block-based corruption.
//  Blocks can: freeze, shift position, corrupt colors, or streak.
//  More aggressive/destructive than BlockFreeze.
//

#include <metal_stdlib>
using namespace metal;

struct GlitchBlocksParams {
    int textureWidth;
    int textureHeight;
    int blockSize;          // Size of glitch blocks
    float glitchAmount;     // Overall probability of glitch (0-1)
    float corruption;       // How corrupted glitched blocks get (0-1)
    uint randomSeed;
    uint frameSeed;         // Changes every frame for animation
};

// Hash for block-level randomness
inline uint blockHash(uint2 blockCoord, uint seed) {
    uint h = blockCoord.x * 374761393u + blockCoord.y * 668265263u + seed;
    h = (h ^ (h >> 13)) * 1274126177u;
    return h ^ (h >> 16);
}

kernel void glitchBlocksKernel(
    texture2d<float, access::read> currentTexture [[texture(0)]],
    texture2d<float, access::read> historyTexture [[texture(1)]],
    texture2d<float, access::write> outputTexture [[texture(2)]],
    constant GlitchBlocksParams& params [[buffer(0)]],
    uint2 gid [[thread_position_in_grid]]
) {
    int width = params.textureWidth;
    int height = params.textureHeight;
    
    if (gid.x >= uint(width) || gid.y >= uint(height)) {
        return;
    }
    
    int blockSize = max(params.blockSize, 4);
    uint2 blockCoord = uint2(gid.x / blockSize, gid.y / blockSize);
    
    // Two hashes: one stable (for which blocks glitch), one changing (for animation)
    uint stableHash = blockHash(blockCoord, params.randomSeed);
    uint animHash = blockHash(blockCoord, params.frameSeed);
    
    float blockRand = float(stableHash & 0xFFFFu) / 65535.0;
    float animRand = float(animHash & 0xFFFFu) / 65535.0;
    
    float4 current = currentTexture.read(gid);
    float4 result;
    
    if (blockRand < params.glitchAmount) {
        // This block is glitched - choose glitch type
        uint glitchType = (stableHash >> 16) % 5;
        
        switch (glitchType) {
            case 0: {
                // FREEZE: show old frame
                result = historyTexture.read(gid);
                break;
            }
            case 1: {
                // SHIFT: sample from offset position
                int shiftX = int((stableHash & 0xFF) % 60) - 30;
                int shiftY = int((stableHash >> 8 & 0xFF) % 60) - 30;
                shiftX = int(float(shiftX) * params.corruption);
                shiftY = int(float(shiftY) * params.corruption);
                
                int2 srcPos = int2(gid) + int2(shiftX, shiftY);
                srcPos = clamp(srcPos, int2(0), int2(width - 1, height - 1));
                result = currentTexture.read(uint2(srcPos));
                break;
            }
            case 2: {
                // COLOR CORRUPT: swap/shift color channels
                float4 hist = historyTexture.read(gid);
                float corr = params.corruption;
                result = float4(
                    mix(current.r, hist.g, corr),
                    mix(current.g, hist.b, corr),
                    mix(current.b, hist.r, corr),
                    current.a
                );
                break;
            }
            case 3: {
                // STREAK: sample from direction
                float angle = animRand * 6.28318;
                float dist = 3.0 + params.corruption * 15.0;
                int2 srcPos = int2(gid) + int2(cos(angle) * dist, sin(angle) * dist);
                srcPos = clamp(srcPos, int2(0), int2(width - 1, height - 1));
                
                float4 streakSample = historyTexture.read(uint2(srcPos));
                result = mix(current, streakSample, 0.5 + params.corruption * 0.4);
                break;
            }
            default: {
                // QUANTIZE: reduce color precision
                float q = 4.0 + (1.0 - params.corruption) * 12.0;
                result = float4(
                    floor(current.r * q) / q,
                    floor(current.g * q) / q,
                    floor(current.b * q) / q,
                    current.a
                );
                break;
            }
        }
    } else {
        // Normal pixel
        result = current;
    }
    
    outputTexture.write(result, gid);
}

