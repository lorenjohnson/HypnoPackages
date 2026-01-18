//
//  BlurTransition.metal
//  HypnoCore
//
//  Gaussian-ish blur into the next clip.
//  Outgoing gets blurrier as progress increases.
//  Incoming starts blurred and sharpens as it takes over.
//

#include "../TransitionCommon.h"

static inline uint2 clampCoord(int2 p, int width, int height) {
    return uint2(uint(clamp(p.x, 0, width - 1)), uint(clamp(p.y, 0, height - 1)));
}

static inline float4 blurSample(
    texture2d<float, access::read> tex,
    uint2 gid,
    int width,
    int height,
    float blurPx
) {
    // No blur
    if (blurPx <= 0.5) {
        return tex.read(gid);
    }

    // Approximate gaussian blur with a small weighted neighborhood.
    // Use 4 rings of offsets scaled by blur amount.
    float unit = blurPx / 4.0;

    int o1 = max(1, int(round(unit * 1.0)));
    int o2 = max(1, int(round(unit * 2.0)));
    int o3 = max(1, int(round(unit * 3.0)));
    int o4 = max(1, int(round(unit * 4.0)));

    int2 p = int2(int(gid.x), int(gid.y));

    // Weights roughly based on a 9-tap gaussian; expanded here for a slightly smoother result.
    // Keep total weight near 1.0.
    float4 sum = float4(0.0);
    float w = 0.0;

    // Center
    float wc = 0.18;
    sum += tex.read(gid) * wc;
    w += wc;

    // Cardinal directions (ring 1)
    float w1 = 0.12;
    sum += tex.read(clampCoord(p + int2( o1,  0), width, height)) * w1;
    sum += tex.read(clampCoord(p + int2(-o1,  0), width, height)) * w1;
    sum += tex.read(clampCoord(p + int2( 0,  o1), width, height)) * w1;
    sum += tex.read(clampCoord(p + int2( 0, -o1), width, height)) * w1;
    w += 4.0 * w1;

    // Diagonals (ring 2)
    float w2 = 0.07;
    sum += tex.read(clampCoord(p + int2( o2,  o2), width, height)) * w2;
    sum += tex.read(clampCoord(p + int2(-o2,  o2), width, height)) * w2;
    sum += tex.read(clampCoord(p + int2( o2, -o2), width, height)) * w2;
    sum += tex.read(clampCoord(p + int2(-o2, -o2), width, height)) * w2;
    w += 4.0 * w2;

    // Wider cardinals (ring 3)
    float w3 = 0.05;
    sum += tex.read(clampCoord(p + int2( o3,  0), width, height)) * w3;
    sum += tex.read(clampCoord(p + int2(-o3,  0), width, height)) * w3;
    sum += tex.read(clampCoord(p + int2( 0,  o3), width, height)) * w3;
    sum += tex.read(clampCoord(p + int2( 0, -o3), width, height)) * w3;
    w += 4.0 * w3;

    // Extra diagonals (ring 4)
    float w4 = 0.03;
    sum += tex.read(clampCoord(p + int2( o4,  o4), width, height)) * w4;
    sum += tex.read(clampCoord(p + int2(-o4,  o4), width, height)) * w4;
    sum += tex.read(clampCoord(p + int2( o4, -o4), width, height)) * w4;
    sum += tex.read(clampCoord(p + int2(-o4, -o4), width, height)) * w4;
    w += 4.0 * w4;

    return sum / max(w, 1e-5);
}

kernel void transitionBlur(
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

    // Max blur in pixels (scaled a bit with resolution, capped).
    float minDim = float(min(params.width, params.height));
    float maxBlur = min(36.0, max(10.0, minDim * 0.025));

    // Outgoing blurs up as it fades out.
    float blurOut = maxBlur * smoothstep(0.0, 0.65, p);

    // Incoming starts blurred and sharpens as it becomes dominant.
    float blurIn = maxBlur * (1.0 - smoothstep(0.35, 1.0, p));

    float4 a = blurSample(outgoing, gid, params.width, params.height, blurOut);
    float4 b = blurSample(incoming, gid, params.width, params.height, blurIn);

    float4 result = mix(a, b, p);
    output.write(result, gid);
}

