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

    float4 a = outgoing.read(gid);
    float4 b = incoming.read(gid);

    // Simple linear blend
    float4 result = mix(a, b, params.progress);
    output.write(result, gid);
}
