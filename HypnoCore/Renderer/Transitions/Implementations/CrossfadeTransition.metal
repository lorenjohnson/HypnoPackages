//
//  CrossfadeTransition.metal
//  HypnoCore
//
//  Simple linear crossfade between two textures.
//

#include "../TransitionCommon.h"

kernel void transitionCrossfade(
    texture2d<float, access::read> outgoing [[texture(0)]],
    texture2d<float, access::read> incoming [[texture(1)]],
    texture2d<float, access::write> output [[texture(2)]],
    constant TransitionParams& params [[buffer(0)]],
    uint2 gid [[thread_position_in_grid]]
) {
    if (gid.x >= uint(params.width) || gid.y >= uint(params.height)) {
        return;
    }

    int outW = params.width;
    int outH = params.height;
    int outSrcW = int(outgoing.get_width());
    int outSrcH = int(outgoing.get_height());
    int inSrcW = int(incoming.get_width());
    int inSrcH = int(incoming.get_height());

    uint2 outPos = mapCoord(gid, outW, outH, outSrcW, outSrcH);
    uint2 inPos = mapCoord(gid, outW, outH, inSrcW, inSrcH);

    float4 a = outgoing.read(outPos);
    float4 b = incoming.read(inPos);

    // Simple linear blend
    float4 result = mix(a, b, params.progress);
    output.write(result, gid);
}
