//
//  TimeShuffleShader.metal
//  Hypnograph
//
//  Time shuffle - swap chunks of frames out of order.
//  Different screen regions show different temporal chunks.
//  Creates organic "scrambled tape" degradation.
//  Regions have irregular boundaries based on noise.
//

#include <metal_stdlib>
using namespace metal;

struct TimeShuffleParams {
    int textureWidth;
    int textureHeight;
    int numRegions;         // Approximate number of regions (2-8)
    int depth;              // How far back in time to sample
    int maxHistoryFrames;   // Available frame buffer depth
    uint shuffleSeed;       // Changes when shuffle happens
    int orientation;        // 0 = horizontal bands, 1 = vertical, 2 = diagonal
};

// Hash function
inline float hash11(float p, uint seed) {
    p = fract(p * 0.1031 + float(seed) * 0.001);
    p *= p + 33.33;
    p *= p + p;
    return fract(p);
}

// 1D noise for irregular boundaries
inline float noise1D(float x, uint seed) {
    float i = floor(x);
    float f = fract(x);
    f = f * f * (3.0 - 2.0 * f);
    return mix(hash11(i, seed), hash11(i + 1.0, seed), f);
}

kernel void timeShuffleKernel(
    array<texture2d<float, access::read>, 8> historyTextures [[texture(0)]],
    texture2d<float, access::write> outputTexture [[texture(8)]],
    constant TimeShuffleParams& params [[buffer(0)]],
    uint2 gid [[thread_position_in_grid]]
) {
    int width = params.textureWidth;
    int height = params.textureHeight;

    if (gid.x >= uint(width) || gid.y >= uint(height)) {
        return;
    }

    float2 uv = float2(gid) / float2(width, height);

    // Choose axis based on orientation
    float axisPos;
    float crossPos;
    if (params.orientation == 0) {
        // Horizontal bands
        axisPos = uv.y;
        crossPos = uv.x;
    } else if (params.orientation == 1) {
        // Vertical bands
        axisPos = uv.x;
        crossPos = uv.y;
    } else {
        // Diagonal
        axisPos = (uv.x + uv.y) * 0.5;
        crossPos = (uv.x - uv.y + 1.0) * 0.5;
    }

    // Add noise to create irregular, rough region boundaries
    // Multiple octaves of noise for more organic edges
    float warp1 = noise1D(crossPos * 2.0, params.shuffleSeed) * 0.2;
    float warp2 = noise1D(crossPos * 5.0, params.shuffleSeed + 1000u) * 0.1;
    float warp3 = noise1D(axisPos * 4.0, params.shuffleSeed + 2000u) * 0.08;
    float warpedPos = axisPos + warp1 + warp2 + warp3;

    // Determine region with irregular boundaries
    int numRegions = clamp(params.numRegions, 2, 8);
    float regionFloat = warpedPos * float(numRegions);
    int regionIndex = clamp(int(regionFloat), 0, numRegions - 1);

    // Hash determines which temporal chunk this region shows
    uint h = uint(regionIndex) * 2654435761u + params.shuffleSeed;
    h = (h ^ (h >> 13)) * 1274126177u;
    h = h ^ (h >> 16);

    // Map hash to a chunk index (0 to 7 for our 8 textures)
    int chunkIndex = int(h % 8);

    // Read from the assigned temporal chunk
    float4 result = historyTextures[chunkIndex].read(gid);

    outputTexture.write(result, gid);
}

