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

    // Intensity peaks mid-transition, but ramps in quickly so it feels destructive.
    float peak = 1.0 - pow(abs(progress - 0.5) * 2.0, 2.0);
    float intensity = max(0.2, peak);
    intensity *= smoothstep(0.05, 0.25, progress) * (1.0 - smoothstep(0.85, 0.98, progress)) + 0.25;

    // Block grid (resolution-aware).
    float blockW = max(14.0, w / 22.0);
    float blockH = max(14.0, h / 16.0);

    // Block coordinates
    float2 blockCoord = float2(floor(float(gid.x) / blockW), floor(float(gid.y) / blockH));
    float blockRand = hash(blockCoord, seed);
    float blockRand2 = hash(blockCoord + float2(7.0, 13.0), seed);
    float blockRand3 = hash(blockCoord + float2(23.0, 41.0), seed);

    // Each block has a "switch time" and a velocity vector to fling fragments.
    float switchPoint = blockRand * 0.65 + 0.12;  // Switch between ~12% and ~77%
    float localT = clamp((progress - switchPoint) / 0.25, 0.0, 1.0); // 0->1 around switch

    float2 v = float2(blockRand2 - 0.5, blockRand3 - 0.5);
    float vLen = max(length(v), 1e-3);
    float2 dir = v / vLen;

    // Fragment displacement grows rapidly as the outgoing clip "falls apart".
    float fragT = clamp(progress * 1.15 - blockRand * 0.15, 0.0, 1.0);
    float fragAmt = (fragT * fragT) * w * 0.22 * intensity; // up to ~22% width
    float2 fragOffset = dir * fragAmt;

    // Add scanline shear + jitter for low-fi breakup.
    float rowRand = hash(float2(float(gid.y) * 0.25, float(seed)), seed);
    float shear = (rowRand - 0.5) * w * 0.06 * intensity;
    float jitter = (hash(float2(float(gid.x), float(gid.y)), seed) - 0.5) * w * 0.01 * intensity;

    // Calculate sample position with displacement
    int2 base = int2(int(gid.x), int(gid.y));
    int2 outPosI = base + int2(int(fragOffset.x + shear + jitter), int(fragOffset.y * 0.35));
    outPosI.x = clamp(outPosI.x, 0, params.width - 1);
    outPosI.y = clamp(outPosI.y, 0, params.height - 1);

    int2 inPosI = base - int2(int(fragOffset.x * 0.15), int(fragOffset.y * 0.10));
    inPosI.x = clamp(inPosI.x, 0, params.width - 1);
    inPosI.y = clamp(inPosI.y, 0, params.height - 1);

    // Read both sources
    float4 a = outgoing.read(uint2(outPosI));
    float4 b = incoming.read(uint2(inPosI));

    // Disintegration mask: as progress increases, more pixels "drop out" of outgoing.
    float2 px = float2(float(gid.x), float(gid.y));
    float noise = hash(px * 0.35 + blockCoord * 3.0, seed);
    float dropout = smoothstep(0.15, 0.95, progress) * smoothstep(0.35, 1.0, noise);

    // Switch within block with a soft band. Before switch, outgoing dominates; after, incoming dominates.
    float mixT = smoothstep(0.0, 1.0, localT);

    // Before switch: mostly outgoing, but with increasing holes.
    // After switch: mostly incoming, with occasional "ghost" fragments of outgoing.
    float hole = clamp(dropout * (1.0 - mixT) + (hash(blockCoord + px * 0.05, seed) * 0.15) * mixT, 0.0, 1.0);
    float4 result = mix(a, b, mixT);
    result = mix(result, b, hole);

    // RGB channel separation - very visible chromatic aberration
    int rgbShift = int(intensity * w * (0.025 + 0.045 * (1.0 - abs(progress - 0.5) * 2.0)));
    if (rgbShift > 0) {
        uint2 rPos = uint2(uint(clamp(int(gid.x) + rgbShift, 0, params.width - 1)), gid.y);
        uint2 bPos = uint2(uint(clamp(int(gid.x) - rgbShift, 0, params.width - 1)), gid.y);

        float4 rSample = mix(outgoing.read(rPos), incoming.read(rPos), mixT);
        float4 bSample = mix(outgoing.read(bPos), incoming.read(bPos), mixT);

        result.r = rSample.r;
        result.b = bSample.b;
    }

    // Scanline corruption - some rows show the "wrong" source
    if (rowRand > 0.82 && intensity > 0.25) {
        int rowShift = int((blockRand2 - 0.5) * w * (0.18 + 0.25 * intensity));
        uint2 rowPos = uint2(uint(clamp(int(gid.x) + rowShift, 0, params.width - 1)), gid.y);
        float4 swapped = mix(incoming.read(rowPos), outgoing.read(rowPos), mixT);
        result = mix(result, swapped, 0.65 * intensity);
    }

    // Low-fi "debris": occasional monochrome blocks and posterized fragments.
    if (blockRand3 > 0.7 && intensity > 0.25) {
        float mono = dot(result.rgb, float3(0.299, 0.587, 0.114));
        float poster = floor(mono * 6.0) / 6.0;
        float amount = (blockRand3 - 0.7) / 0.3;
        result.rgb = mix(result.rgb, float3(poster), amount * 0.55 * intensity);
    }

    // Random flash blocks
    if (blockRand > 0.9 && intensity > 0.35) {
        float flicker = hash(blockCoord + float2(progress * 60.0, progress * 90.0), seed);
        result = mix(result, float4(flicker, flicker, flicker, 1.0), 0.6 * intensity);
    }

    output.write(result, gid);
}
