//
//  DestroyTransition.metal
//  HypnoCore
//
//  Datamosh/glitch effect that tears between the two sources.
//  Creates visible block displacement, RGB separation, and chaotic source mixing.
//

#include "../TransitionCommon.h"

kernel void transitionDestroy(
    texture2d<float, access::read> outgoing [[texture(0)]],
    texture2d<float, access::read> incoming [[texture(1)]],
    texture2d<float, access::write> output [[texture(2)]],
    constant TransitionParams& params [[buffer(0)]],
    uint2 gid [[thread_position_in_grid]]
) {
    if (gid.x >= uint(params.width) || gid.y >= uint(params.height)) {
        return;
    }

    float progress = params.progress;
    uint seed = params.seed;
    float w = float(params.width);
    float h = float(params.height);

    // Glitch intensity - always present but peaks in middle
    // Use a wider curve so effects are visible throughout
    float intensity = 1.0 - pow(abs(progress - 0.5) * 2.0, 2.0);
    intensity = max(intensity, 0.15);  // Minimum intensity so there's always some effect

    // Fixed block grid - 12x8 blocks
    float blockW = w / 12.0;
    float blockH = h / 8.0;

    // Block coordinates
    float2 blockCoord = float2(floor(float(gid.x) / blockW), floor(float(gid.y) / blockH));
    float blockRand = hash(blockCoord, seed);
    float blockRand2 = hash(blockCoord + float2(7.0, 13.0), seed);
    float blockRand3 = hash(blockCoord + float2(23.0, 41.0), seed);

    // Strong horizontal displacement - THIS IS THE KEY VISUAL
    float displacement = 0.0;
    if (blockRand > 0.25) {
        // Shift entire blocks horizontally by up to 25% of screen width
        displacement = (blockRand2 - 0.5) * w * 0.5 * intensity;
    }

    // Calculate sample position with displacement
    int sampleX = clamp(int(gid.x) + int(displacement), 0, params.width - 1);
    uint2 samplePos = uint2(sampleX, gid.y);

    // Read both sources
    float4 a = outgoing.read(samplePos);
    float4 b = incoming.read(samplePos);

    // Source selection based on progress
    // Each block switches at a different time based on its random value
    float switchPoint = blockRand * 0.6 + 0.2;  // Switch between 20% and 80% progress
    bool useIncoming = progress > switchPoint;
    float4 result = useIncoming ? b : a;

    // RGB channel separation - very visible chromatic aberration
    int rgbShift = int(intensity * w * 0.05);
    if (rgbShift > 0) {
        uint2 rPos = uint2(clamp(sampleX + rgbShift, 0, params.width - 1), gid.y);
        uint2 bPos = uint2(clamp(sampleX - rgbShift, 0, params.width - 1), gid.y);

        float4 rSample = useIncoming ? incoming.read(rPos) : outgoing.read(rPos);
        float4 bSample = useIncoming ? incoming.read(bPos) : outgoing.read(bPos);

        result.r = rSample.r;
        result.b = bSample.b;
    }

    // Scanline corruption - some rows show the "wrong" source
    float rowRand = hash(float2(float(gid.y), float(seed)), seed);
    if (rowRand > 0.85) {
        // This row shows the opposite source with horizontal shift
        int rowShift = int((blockRand2 - 0.5) * w * 0.3);
        uint2 rowPos = uint2(clamp(int(gid.x) + rowShift, 0, params.width - 1), gid.y);
        result = useIncoming ? outgoing.read(rowPos) : incoming.read(rowPos);
    }

    // Block color effects
    if (blockRand3 > 0.75 && intensity > 0.3) {
        if (blockRand > 0.5) {
            // Invert colors
            result.rgb = 1.0 - result.rgb;
        } else {
            // Saturate/boost
            result.rgb = saturate(result.rgb * 1.5);
        }
    }

    // Random flash blocks
    if (blockRand > 0.88 && intensity > 0.4) {
        result = float4(blockRand2, blockRand2, blockRand2, 1.0);
    }

    output.write(result, gid);
}
