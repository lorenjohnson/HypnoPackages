//
//  Passthrough.metal
//  HypnoCore
//
//  Simple vertex/fragment shaders for rendering a texture to screen.
//  Used by RendererView for basic texture display.
//

#include <metal_stdlib>
using namespace metal;

// Vertex input from CPU
struct VertexIn {
    float2 position [[attribute(0)]];
    float2 texCoord [[attribute(1)]];
};

// Vertex output / Fragment input
struct VertexOut {
    float4 position [[position]];
    float2 texCoord;
};

// Transform parameters: (scaleX, scaleY, offsetX, offsetY)
// Used for aspect ratio handling
struct Transform {
    float4 params;  // x=scaleX, y=scaleY, z=offsetX, w=offsetY
};

// MARK: - Passthrough Vertex Shader

vertex VertexOut passthroughVertex(
    uint vertexID [[vertex_id]],
    const device float4* vertices [[buffer(0)]],  // packed as (posX, posY, texU, texV)
    constant float4& transform [[buffer(1)]]
) {
    // Unpack vertex data
    float4 vtx = vertices[vertexID];
    float2 position = vtx.xy;
    float2 texCoord = vtx.zw;

    // Apply transform for aspect ratio
    float2 scale = transform.xy;
    float2 offset = transform.zw;

    VertexOut out;
    out.position = float4(position * scale + offset, 0.0, 1.0);
    out.texCoord = texCoord;
    return out;
}

// MARK: - Passthrough Fragment Shader

fragment float4 passthroughFragment(
    VertexOut in [[stage_in]],
    texture2d<float, access::sample> texture [[texture(0)]],
    sampler textureSampler [[sampler(0)]]
) {
    return texture.sample(textureSampler, in.texCoord);
}

// MARK: - Solid Color Fragment (for testing/debugging)

fragment float4 solidColorFragment(
    VertexOut in [[stage_in]],
    constant float4& color [[buffer(0)]]
) {
    return color;
}
