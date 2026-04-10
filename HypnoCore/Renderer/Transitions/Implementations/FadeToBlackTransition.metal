//
//  FadeToBlackTransition.metal
//  HypnoCore
//
//  Fade outgoing to black, then fade in the incoming clip from black.
//  There is no overlap between the two sources.
//

#include "../TransitionCommon.h"

kernel void transitionFadeToBlack(
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

    float4 outgoingColor = outgoing.read(outPos);
    float4 incomingColor = incoming.read(inPos);
    float4 black = float4(0.0, 0.0, 0.0, 1.0);

    float progress = clamp(params.progress, 0.0, 1.0);
    float4 result;

    if (progress < 0.5) {
        float fadeOut = progress / 0.5;
        result = mix(outgoingColor, black, fadeOut);
    } else {
        float fadeIn = (progress - 0.5) / 0.5;
        result = mix(black, incomingColor, fadeIn);
    }

    output.write(result, gid);
}
