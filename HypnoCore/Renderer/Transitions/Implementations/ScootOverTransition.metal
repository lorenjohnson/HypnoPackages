//
//  ScootOverTransition.metal
//  HypnoCore
//
//  Both clips are visible during the transition:
//  - Incoming occupies the left side and "scoots" the boundary to the right.
//  - Outgoing remains on the right until it is fully replaced.
//  Adds light film-strip style jitter/flicker to feel imperfect/out-of-sync.
//

#include "../TransitionCommon.h"

static inline uint2 clampCoord(int2 p, int width, int height) {
    return uint2(uint(clamp(p.x, 0, width - 1)), uint(clamp(p.y, 0, height - 1)));
}

kernel void transitionScootOver(
    texture2d<float, access::read> outgoing [[texture(0)]],
    texture2d<float, access::read> incoming [[texture(1)]],
    texture2d<float, access::write> output [[texture(2)]],
    constant TransitionParams& params [[buffer(0)]],
    uint2 gid [[thread_position_in_grid]]
) {
    if (gid.x >= uint(params.width) || gid.y >= uint(params.height)) {
        return;
    }

    float p = clamp(params.progress, 0.0, 1.0);
    if (p <= 0.001) {
        output.write(outgoing.read(gid), gid);
        return;
    }
    if (p >= 0.999) {
        output.write(incoming.read(gid), gid);
        return;
    }

    float2 px = float2(float(gid.x), float(gid.y));
    float w = float(params.width);
    float h = float(params.height);

    // Boundary moves left->right. Left side is incoming, right side is outgoing.
    float cutX = p * w;
    float softnessPx = max(1.0, params.softness * w * 0.9 + 2.0);
    float mask = smoothstep(cutX - softnessPx, cutX + softnessPx, px.x); // 0=left(incoming), 1=right(outgoing)

    // Film-strip imperfection: jitter scanline bands + mild flicker.
    float intensity = 0.35 + 0.65 * (1.0 - abs(p - 0.5) * 2.0); // strongest mid-transition

    float band = floor(px.y / 7.0);
    float tA = floor(p * 72.0);
    float tB = floor(p * 97.0);

    float bandRandA = hash(float2(band, tA), params.seed);
    float bandRandB = hash(float2(band + 13.0, tB), params.seed);

    float bandJitterX = (bandRandA - 0.5) * w * 0.010 * intensity;
    float bandJitterY = (bandRandB - 0.5) * h * 0.003 * intensity;

    // Make incoming feel slightly "late"/mis-registered at the start.
    float incomingSlide = (1.0 - p) * w * 0.07;
    float outgoingSlide = p * w * 0.02;

    int2 base = int2(int(gid.x), int(gid.y));

    int2 inPosI = int2(
        int(px.x - incomingSlide + bandJitterX),
        int(px.y + bandJitterY)
    );
    int2 outPosI = int2(
        int(px.x + outgoingSlide - bandJitterX * 0.6),
        int(px.y - bandJitterY * 0.4)
    );

    uint2 inPos = clampCoord(inPosI, params.width, params.height);
    uint2 outPos = clampCoord(outPosI, params.width, params.height);

    float4 a = outgoing.read(outPos);
    float4 b = incoming.read(inPos);

    float4 result = mix(b, a, mask);

    // Add "out of sync film strip" feeling near the boundary:
    // - intermittent row swaps
    // - subtle brightness flicker
    float seam = 1.0 - saturate(abs(px.x - cutX) / (softnessPx * 3.0));
    float rowGate = hash(float2(band, floor(p * 38.0)), params.seed);
    if (seam > 0.05 && rowGate > (0.72 - 0.18 * intensity)) {
        // Alternate which source leaks per row/band.
        float alt = step(1.0, fmod(px.y + floor(p * 41.0), 2.0));
        float4 leaked = mix(a, b, alt);
        result = mix(result, leaked, seam * 0.45 * intensity);
    }

    float flicker = (hash(float2(band, floor(p * 120.0)), params.seed) - 0.5) * 0.10 * intensity;
    result.rgb = saturate(result.rgb * (1.0 + flicker));

    // Occasional vertical scratches (very subtle).
    float scratchGate = hash(float2(floor(px.x / 3.0), floor(p * 140.0)), params.seed);
    float scratch = step(0.997, scratchGate) * (0.12 + 0.18 * intensity);
    result.rgb = saturate(result.rgb + scratch);

    output.write(result, gid);
}

