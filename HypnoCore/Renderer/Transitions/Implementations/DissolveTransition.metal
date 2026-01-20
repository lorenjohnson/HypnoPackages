//
//  DissolveTransition.metal
//  HypnoCore
//
//  Noise-based dissolve from outgoing to incoming.
//  Designed to feel destructive but remain watchable (no large displacement).
//

#include "../TransitionCommon.h"

kernel void transitionDissolve(
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
    float2 px = float2(float(gid.x), float(gid.y));

    int outW = params.width;
    int outH = params.height;
    int outSrcW = int(outgoing.get_width());
    int outSrcH = int(outgoing.get_height());
    int inSrcW = int(incoming.get_width());
    int inSrcH = int(incoming.get_height());

    uint2 outPos = mapCoord(gid, outW, outH, outSrcW, outSrcH);
    uint2 inPos = mapCoord(gid, outW, outH, inSrcW, inSrcH);

    if (p <= 0.001) {
        output.write(outgoing.read(outPos), gid);
        return;
    }
    if (p >= 0.999) {
        output.write(incoming.read(inPos), gid);
        return;
    }

    // Multi-scale noise: combine a fine grain with a blockier field.
    float2 block = floor(px / float2(18.0, 14.0));
    float nFine = hash(px * 0.20, params.seed);
    float nBlock = hash(block, params.seed);
    float n = mix(nFine, nBlock, 0.55);

    // Ease curve for threshold progression.
    float t = smoothstep(0.0, 1.0, p);

    // Soft threshold band to avoid harsh popping.
    float softness = 0.10;
    // "Incoming when threshold exceeds noise" so it starts mostly outgoing and ends fully incoming.
    float mask = smoothstep(n - softness, n + softness, t);

    float4 a = outgoing.read(outPos);
    float4 b = incoming.read(inPos);

    // Add a touch of low-fi grit near the edge of the dissolve.
    float edge = 1.0 - saturate(abs(n - t) / softness);
    float grit = floor(hash(px * 0.9 + float2(t * 120.0, t * 70.0), params.seed) * 5.0) / 5.0;
    float4 gritColor = float4(grit, grit, grit, 1.0);

    float gritAmount = edge * (0.10 + 0.20 * (1.0 - abs(p - 0.5) * 2.0));
    float4 mixed = mix(a, b, mask);
    float4 result = mix(mixed, gritColor, gritAmount);

    output.write(result, gid);
}
