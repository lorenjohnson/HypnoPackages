//
//  SlideLeftTransition.metal
//  HypnoCore
//
//  Both clips are visible during the transition:
//  - Outgoing slides left offscreen.
//  - Incoming enters from the right.
//  Adds light film-strip style jitter/flicker to feel imperfect/out-of-sync.
//

#include "../TransitionCommon.h"

kernel void transitionSlideLeft(
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
    int outW = params.width;
    int outH = params.height;
    int outSrcW = int(outgoing.get_width());
    int outSrcH = int(outgoing.get_height());
    int inSrcW = int(incoming.get_width());
    int inSrcH = int(incoming.get_height());

    if (p <= 0.001) {
        output.write(outgoing.read(mapCoord(gid, outW, outH, outSrcW, outSrcH)), gid);
        return;
    }
    if (p >= 0.999) {
        output.write(incoming.read(mapCoord(gid, outW, outH, inSrcW, inSrcH)), gid);
        return;
    }

    float2 px = float2(float(gid.x), float(gid.y));
    float w = float(params.width);
    float h = float(params.height);

    // Film-strip imperfection: jitter scanline bands + mild flicker + stuttery motion.
    float intensity = 0.35 + 0.65 * (1.0 - abs(p - 0.5) * 2.0); // strongest mid-transition

    // Monotonic "stutter": slightly hold then catch up within small progress steps.
    // Keep it subtle and mostly mid-transition (film strip isn't perfectly smooth).
    float stutterAmount = smoothstep(0.10, 0.32, p) * (1.0 - smoothstep(0.70, 0.92, p));
    float stepsF = mix(1.0, 48.0, intensity);
    float sp = p * stepsF;
    float base = floor(sp);
    float f = fract(sp);
    float hold = mix(0.05, 0.22, intensity) * stutterAmount;
    float fEase = smoothstep(hold, 1.0, f);
    float pStutter = (base + fEase) / max(stepsF, 1.0);
    float p2 = mix(p, pStutter, 0.20 * stutterAmount);

    float band = floor(px.y / 7.0);
    float tA = floor(p2 * 72.0);
    float tB = floor(p2 * 97.0);

    float bandRandA = hash(float2(band, tA), params.seed);
    float bandRandB = hash(float2(band + 13.0, tB), params.seed);

    float bandJitterX = (bandRandA - 0.5) * w * 0.010 * intensity;
    float bandJitterY = (bandRandB - 0.5) * h * 0.003 * intensity;

    // Treat outgoing+incoming as a single connected strip: [outgoing][incoming]
    // Viewport slides RIGHT across the strip, which reads as the old clip moving LEFT and
    // the new clip entering from the RIGHT.
    float stripX = px.x + p2 * w;
    float stripY = px.y;

    // Apply jitter to the strip sample location (so both clips move together as one piece).
    stripX += bandJitterX;
    stripY += bandJitterY;

    float seamX = (1.0 - p2) * w; // where the join between outgoing/incoming appears in viewport

    float4 result;
    if (stripX < w) {
        uint2 outPos = mapCoord(float2(stripX, stripY), outW, outH, outSrcW, outSrcH);
        result = outgoing.read(outPos);
    } else {
        uint2 inPos = mapCoord(float2(stripX - w, stripY), outW, outH, inSrcW, inSrcH);
        result = incoming.read(inPos);
    }

    // Add "out of sync film strip" feeling near the boundary:
    // - intermittent row swaps
    // - subtle brightness flicker
    float seam = 1.0 - saturate(abs(px.x - seamX) / max(2.0, w * 0.018));
    float rowGate = hash(float2(band, floor(p2 * 38.0)), params.seed);
    if (seam > 0.05 && rowGate > (0.72 - 0.18 * intensity)) {
        // Alternate which side leaks per row/band.
        float alt = step(1.0, fmod(px.y + floor(p2 * 41.0), 2.0));
        float stripLeakX = px.x + p2 * w + bandJitterX + (alt > 0.5 ? w * 0.012 : -w * 0.012);
        float stripLeakY = px.y + bandJitterY;
        float4 leaked;
        if (stripLeakX < w) {
            leaked = outgoing.read(mapCoord(float2(stripLeakX, stripLeakY), outW, outH, outSrcW, outSrcH));
        } else {
            leaked = incoming.read(mapCoord(float2(stripLeakX - w, stripLeakY), outW, outH, inSrcW, inSrcH));
        }
        result = mix(result, leaked, seam * 0.55 * intensity);
    }

    float flicker = (hash(float2(band, floor(p2 * 120.0)), params.seed) - 0.5) * 0.10 * intensity;
    result.rgb = saturate(result.rgb * (1.0 + flicker));

    // Occasional vertical scratches (very subtle).
    float scratchGate = hash(float2(floor(px.x / 3.0), floor(p2 * 140.0)), params.seed);
    float scratch = step(0.997, scratchGate) * (0.12 + 0.18 * intensity);
    result.rgb = saturate(result.rgb + scratch);

    // A clearer divide line between frames (slightly dirty, not a perfect vector line).
    float lineW = 0.9 + 1.0 * intensity;
    float line = 1.0 - smoothstep(0.0, lineW, abs(px.x - seamX));
    float lineNoise = hash(float2(band + floor(p2 * 22.0), 91.0), params.seed);
    // Black seam edge, with slight density variation.
    float3 lineColor = float3(0.0);
    float lineAmount = line * (0.25 + 0.25 * intensity) * (0.65 + 0.35 * lineNoise);
    result.rgb = saturate(mix(result.rgb, lineColor, lineAmount));

    output.write(result, gid);
}
