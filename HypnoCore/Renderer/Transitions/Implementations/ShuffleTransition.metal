//
//  ShuffleTransition.metal
//  HypnoCore
//
//  Datamosh/glitch effect that tears between the two sources.
//  Creates visible block displacement, RGB separation, and chaotic source mixing.
//

#include "../TransitionCommon.h"

static inline uint2 wrapCoord(int2 p, int width, int height) {
    int x = p.x % width;
    int y = p.y % height;
    if (x < 0) { x += width; }
    if (y < 0) { y += height; }
    return uint2(uint(x), uint(y));
}

kernel void transitionShuffle(
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

    // Intensity peaks mid-transition, but must read immediately.
    float peak = 1.0 - pow(abs(progress - 0.5) * 2.0, 2.0);
    float intensity = max(0.75, peak);
    intensity *= (1.0 + 0.70 * smoothstep(0.0, 0.10, progress));
    intensity *= (1.0 + 0.35 * peak);

    // Fade heavy displacement out by the end to avoid a visible "snap back".
    float settle = 1.0 - smoothstep(0.72, 0.98, progress);

    // Block grid (resolution-aware).
    float blockW = max(14.0, w / 22.0);
    float blockH = max(14.0, h / 16.0);

    // Block coordinates
    float2 blockCoord = float2(floor(float(gid.x) / blockW), floor(float(gid.y) / blockH));
    float blockRand = hash(blockCoord, seed);
    float blockRand2 = hash(blockCoord + float2(7.0, 13.0), seed);
    float blockRand3 = hash(blockCoord + float2(23.0, 41.0), seed);

    // Each block has a "switch time" and a velocity vector to fling fragments.
    float switchPoint = blockRand * 0.55 + 0.02;  // Switch between ~2% and ~57%
    float localT = clamp((progress - switchPoint) / 0.18, 0.0, 1.0); // 0->1 around switch

    float2 v = float2(blockRand2 - 0.5, blockRand3 - 0.5);
    float vLen = max(length(v), 1e-3);
    float2 dir = v / vLen;

    // Fragment displacement grows rapidly as the outgoing clip "falls apart".
    float fragT = clamp(progress * 1.9 + 0.18 - blockRand * 0.30, 0.0, 1.0);
    float fragAmt = (fragT * fragT) * w * 0.38 * intensity * settle; // fade out by end
    float2 fragOffset = dir * fragAmt;

    // Add scanline shear + jitter for low-fi breakup.
    float rowRand = hash(float2(float(gid.y) * 0.25, float(seed)), seed);
    float shear = (rowRand - 0.5) * w * 0.10 * intensity * settle;
    float jitter = (hash(float2(float(gid.x), float(gid.y)), seed) - 0.5) * w * 0.02 * intensity * settle;

    // Calculate sample position with displacement
    int2 base = int2(int(gid.x), int(gid.y));
    int2 outPosI = base + int2(int(fragOffset.x + shear + jitter), int(fragOffset.y * 0.75));
    outPosI.x = clamp(outPosI.x, 0, params.width - 1);
    outPosI.y = clamp(outPosI.y, 0, params.height - 1);

    int2 inPosI = base - int2(int(fragOffset.x * 0.22), int(fragOffset.y * 0.18));
    inPosI.x = clamp(inPosI.x, 0, params.width - 1);
    inPosI.y = clamp(inPosI.y, 0, params.height - 1);

    // Read both sources
    float4 a = outgoing.read(uint2(outPosI));
    float4 b = incoming.read(uint2(inPosI));

    // Disintegration mask: as progress increases, more pixels "drop out" of outgoing.
    float2 px = float2(float(gid.x), float(gid.y));
    float noise = hash(px * 0.55 + blockCoord * 4.0, seed);
    float dropout = smoothstep(0.0, 0.40, progress) * smoothstep(0.15, 1.0, noise);

    // Switch within block with a soft band. Before switch, outgoing dominates; after, incoming dominates.
    float mixT = smoothstep(0.15, 0.85, localT);

    // Before switch: mostly outgoing, but with increasing holes.
    // After switch: mostly incoming, with occasional "ghost" fragments of outgoing.
    float hole = clamp(dropout * (1.0 - mixT) + (hash(blockCoord + px * 0.07, seed) * 0.35) * mixT, 0.0, 1.0);

    // Make the breakup obvious: outgoing collapses into noise/black before revealing incoming.
    float grain = hash(px * 1.7 + float2(progress * 240.0, progress * 140.0), seed);
    float dust = floor(grain * 6.0) / 6.0;
    float4 debris = float4(dust, dust, dust, 1.0);

    float preBreak = smoothstep(0.0, 0.24, progress);
    float breakMask = clamp(hole * 1.15 + preBreak * 0.35, 0.0, 1.0);
    float blackMask = step(0.45, noise) * breakMask * (1.0 - mixT);

    float4 outGlitched = mix(a, debris, breakMask);
    outGlitched.rgb = mix(outGlitched.rgb, float3(0.0), blackMask);

    // Incoming arrives through the same debris field (still glitchy early).
    float inDebris = (1.0 - smoothstep(0.35, 0.85, progress)) * (0.35 + 0.65 * intensity);
    float4 inGlitched = mix(b, debris, inDebris * (0.35 + 0.65 * dropout));

    float4 result = mix(outGlitched, inGlitched, mixT);

    // Aggressive horizontal tears (multiple regions), strongest mid-transition and mostly gone by the end.
    // Key goals:
    // - Not pinned to any edge (avoid clamping artifacts) -> wrap coordinates.
    // - More frequent, but lower displacement -> favors "tearing" over "sliding the whole frame".
    float tearStrength = smoothstep(0.05, 0.28, progress) * (1.0 - smoothstep(0.80, 0.96, progress));
    float midTear = smoothstep(0.18, 0.40, progress) * (1.0 - smoothstep(0.58, 0.82, progress));
    tearStrength = saturate(max(tearStrength, midTear) * (0.90 + 0.70 * intensity));
    float tA = floor(progress * 72.0);
    float tB = floor(progress * 49.0);
    float yShiftA = hash(float2(17.0, tA), seed) * h;
    float yShiftB = hash(float2(23.0, tB), seed + 1337) * h;
    float xShiftA = hash(float2(31.0, tA), seed + 7) * w;
    float xShiftB = hash(float2(37.0, tB), seed + 99) * w;

    float band1 = hash(float2(floor((px.y + yShiftA) / 6.0), floor((px.x + xShiftA) / 84.0) + tA), seed);
    float band2 = hash(float2(floor((px.y + yShiftB) / 11.0), floor((px.x + xShiftB) / 112.0) + tB), seed + 1337);
    float band3 = hash(float2(floor((px.y + yShiftA * 0.63) / 5.0), floor((px.x + xShiftB) / 64.0) + tB), seed + 4242);

    float thresh1 = mix(0.96, 0.48, tearStrength) - 0.10 * intensity;
    float thresh2 = mix(0.96, 0.52, tearStrength) - 0.10 * intensity;
    float thresh3 = mix(0.97, 0.54, tearStrength) - 0.08 * intensity;

    float tearMask1 = smoothstep(thresh1, 1.0, band1) * tearStrength;
    float tearMask2 = smoothstep(thresh2, 1.0, band2) * tearStrength;
    float tearMask3 = smoothstep(thresh3, 1.0, band3) * tearStrength;

    if (tearMask1 > 0.001) {
        float tearRand = hash(float2(floor((px.y + yShiftA) / 6.0), tA), seed);
        int tearShift = int((tearRand - 0.5) * w * (0.03 + 0.08 * intensity) * tearStrength);
        int yTear = int((hash(float2(floor(tA), floor((px.y + yShiftA) / 19.0)), seed) - 0.5) * h * 0.016 * intensity * tearStrength);
        uint2 tearPos = wrapCoord(base + int2(tearShift, yTear), params.width, params.height);
        float4 torn = mix(incoming.read(tearPos), outgoing.read(tearPos), mixT);
        result = mix(result, torn, tearMask1 * (0.75 + 0.35 * intensity));
    }

    if (tearMask2 > 0.001) {
        float tearRand = hash(float2(floor((px.y + yShiftB) / 11.0), tB), seed + 1337);
        int tearShift = int((tearRand - 0.5) * w * (0.03 + 0.09 * intensity) * tearStrength);
        int yTear = int((hash(float2(floor(tB), floor((px.y + yShiftB) / 23.0)), seed + 7) - 0.5) * h * 0.018 * intensity * tearStrength);
        uint2 tearPos = wrapCoord(base + int2(-tearShift, -yTear), params.width, params.height);
        float4 torn = mix(incoming.read(tearPos), outgoing.read(tearPos), mixT);
        result = mix(result, torn, tearMask2 * (0.75 + 0.35 * intensity));
    }

    if (tearMask3 > 0.001) {
        float tearRand = hash(float2(floor((px.y + yShiftA * 0.63) / 5.0), tB), seed + 4242);
        int tearShift = int((tearRand - 0.5) * w * (0.02 + 0.07 * intensity) * tearStrength);
        int yTear = int((hash(float2(floor(tB), floor((px.y + yShiftB) / 17.0)), seed + 99) - 0.5) * h * 0.014 * intensity * tearStrength);
        uint2 tearPos = wrapCoord(base + int2(tearShift, -yTear), params.width, params.height);
        float4 torn = mix(incoming.read(tearPos), outgoing.read(tearPos), mixT);
        result = mix(result, torn, tearMask3 * (0.70 + 0.40 * intensity));
    }

    // A guaranteed mid-transition "full-frame" tear: many scanline segments shift at once.
    // This makes Shuffle feel meaningfully different from smaller RGB shifts.
    float globalTear = smoothstep(0.22, 0.40, progress) * (1.0 - smoothstep(0.60, 0.86, progress));
    if (globalTear > 0.001) {
        float segH = 3.0 + 9.0 * (1.0 - min(intensity, 1.0));
        float seg = floor((px.y + yShiftB) / segH);
        float segRand = hash(float2(seg, floor(progress * 85.0)), seed + 202);
        int sx = int((segRand - 0.5) * w * (0.02 + 0.08 * intensity) * globalTear);
        uint2 gPos = wrapCoord(base + int2(sx, 0), params.width, params.height);
        float4 gSample = mix(incoming.read(gPos), outgoing.read(gPos), mixT);
        result = mix(result, gSample, globalTear * (0.40 + 0.50 * intensity));
    }

    // Visible randomized RGB jitter (small, frequent, time-varying).
    float rgbBand = hash(float2(floor((px.y + yShiftA) / 8.0), floor(progress * 104.0)), seed + 99);
    float rgbJitterGate = hash(blockCoord + float2(floor(progress * 49.0), 111.0), seed);
    if (rgbJitterGate > 0.42 && rgbBand > (0.62 - 0.22 * intensity)) {
        float2 j = float2(
            (hash(px * 0.23 + float2(12.0, 34.0), seed) - 0.5),
            (hash(px * 0.21 + float2(56.0, 78.0), seed) - 0.5)
        );
        float jitterStrength = max(tearStrength, 0.35 * peak) * settle;
        int jx = int(j.x * w * (0.016 + 0.045 * intensity) * jitterStrength);
        int jy = int(j.y * h * (0.012 + 0.028 * intensity) * jitterStrength);
        uint2 jPos = wrapCoord(base + int2(jx, jy), params.width, params.height);
        float4 jitterSample = mix(outgoing.read(jPos), incoming.read(jPos), mixT);

        // Randomly choose which channels to perturb for "glitch" feel.
        float chanGate = hash(blockCoord + float2(9.0, floor(progress * 23.0)), seed);
        result.r = mix(result.r, jitterSample.r, 0.95 * intensity * jitterStrength);
        if (chanGate > 0.33) {
            result.b = mix(result.b, jitterSample.b, 0.95 * intensity * jitterStrength);
        }
        if (chanGate > 0.78) {
            result.g = mix(result.g, jitterSample.g, 0.70 * intensity * jitterStrength);
        }
    }

    // RGB channel separation - very visible chromatic aberration
    // Make channel separation feel glitchy (sporadic and block/time dependent), not constant.
    float rgbGate = hash(blockCoord + float2(floor(progress * 28.0), 19.0), seed);
    float rgbPixelGate = hash(px * 0.15 + blockCoord * 2.0, seed);
    bool doRGB = (rgbGate > 0.55) && (rgbPixelGate > (0.65 - 0.25 * intensity));

    if (doRGB) {
        // Randomize shift magnitude and direction per block, with occasional spikes.
        float magRand = hash(blockCoord + float2(91.0, 37.0), seed);
        float spike = step(0.92, hash(blockCoord + float2(floor(progress * 11.0), 3.0), seed));

        float baseMag = w * (0.006 + 0.030 * magRand);
        float rgbMagF = baseMag * (0.35 + 0.95 * intensity) * (spike > 0.0 ? 1.8 : 1.0);
        int rgbMag = int(clamp(rgbMagF, 1.0, w * 0.08));

        float dirRand = hash(blockCoord + float2(13.0, 57.0), seed);
        int sx = (dirRand > 0.5) ? rgbMag : -rgbMag;
        int sy = int((hash(blockCoord + float2(5.0, 99.0), seed) - 0.5) * float(rgbMag) * 0.35);

        uint2 rPos = uint2(
            uint(clamp(int(gid.x) + sx, 0, params.width - 1)),
            uint(clamp(int(gid.y) + sy, 0, params.height - 1))
        );
        uint2 bPos = uint2(
            uint(clamp(int(gid.x) - sx, 0, params.width - 1)),
            uint(clamp(int(gid.y) - sy, 0, params.height - 1))
        );

        float4 rSample = mix(outgoing.read(rPos), incoming.read(rPos), mixT);
        float4 bSample = mix(outgoing.read(bPos), incoming.read(bPos), mixT);

        // Occasional channel swap (low-fi glitch) instead of pure shift.
        float swapGate = hash(blockCoord + float2(floor(progress * 19.0), 71.0), seed);
        if (swapGate > 0.92) {
            result.rg = result.gr;
        } else {
            result.r = rSample.r;
            result.b = bSample.b;
        }
    }

    // Scanline corruption - some rows show the "wrong" source
    if (rowRand > 0.75 && intensity > 0.25) {
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
