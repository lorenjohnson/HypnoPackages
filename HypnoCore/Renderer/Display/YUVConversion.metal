//
//  YUVConversion.metal
//  HypnoCore
//
//  Metal compute shaders for YUV to RGB conversion.
//  Supports BT.601 and BT.709 color matrices, video range and full range.
//

#include <metal_stdlib>
using namespace metal;

// MARK: - Color Matrices

// BT.709 YUV to RGB conversion (HD content)
// Used for most modern HD/4K video
constant float3x3 bt709Matrix = float3x3(
    float3(1.0,     1.0,      1.0),
    float3(0.0,    -0.18732,  1.8556),
    float3(1.5748, -0.46812,  0.0)
);

// BT.601 YUV to RGB conversion (SD content)
// Used for older SD video, some webcams
constant float3x3 bt601Matrix = float3x3(
    float3(1.0,    1.0,      1.0),
    float3(0.0,   -0.34414,  1.772),
    float3(1.402, -0.71414,  0.0)
);

// MARK: - Parameters

struct YUVConversionParams {
    int width;
    int height;
    int useBT709;      // 1 = BT.709, 0 = BT.601
    int isVideoRange;  // 1 = video range (16-235), 0 = full range (0-255)
    int isTenBit;      // 1 = 10-bit (stored in 16-bit lanes), 0 = 8-bit
};

// MARK: - YUV to RGBA Compute Kernel

kernel void yuvToRGBA(
    texture2d<float, access::read> yTexture [[texture(0)]],
    texture2d<float, access::read> cbcrTexture [[texture(1)]],
    texture2d<float, access::write> outTexture [[texture(2)]],
    constant YUVConversionParams& params [[buffer(0)]],
    uint2 gid [[thread_position_in_grid]]
) {
    // Bounds check
    if (gid.x >= uint(params.width) || gid.y >= uint(params.height)) {
        return;
    }

    // Sample Y at full resolution
    float y = yTexture.read(gid).r;

    // Sample CbCr at half resolution (chroma subsampling)
    uint2 chromaCoord = gid / 2;
    float2 cbcr = cbcrTexture.read(chromaCoord).rg;

    // Handle 8-bit vs 10-bit, and video range vs full range.
    if (params.isTenBit != 0) {
        // CV 10-bit bi-planar formats are stored in 16-bit lanes (P010-style).
        // Convert back to 10-bit nominal values by undoing the left-shift (<< 6).
        float y10 = (y * 65535.0) / 64.0;         // ~0...1023
        float2 cbcr10 = (cbcr * 65535.0) / 64.0;  // ~0...1023

        if (params.isVideoRange != 0) {
            // Video range (10-bit): Y [64-940], CbCr [64-960] centered at 512.
            y = (y10 - 64.0) / 876.0;
            cbcr = (cbcr10 - 512.0) / 896.0;
        } else {
            // Full range (10-bit): Y [0-1023], CbCr centered at 512.
            y = y10 / 1023.0;
            cbcr = (cbcr10 - 512.0) / 1023.0;
        }
    } else {
        // 8-bit.
        if (params.isVideoRange != 0) {
            // Video range: Y [16-235] -> [0-1], CbCr [16-240] centered at 128
            y = (y * 255.0 - 16.0) / 219.0;
            cbcr = (cbcr * 255.0 - 128.0) / 224.0;
        } else {
            // Full range: Y [0-255] -> [0-1], CbCr centered at 0.5
            cbcr = cbcr - 0.5;
        }
    }

    // Select color matrix
    float3x3 matrix = params.useBT709 != 0 ? bt709Matrix : bt601Matrix;

    // Convert YUV to RGB
    float3 yuv = float3(y, cbcr.r, cbcr.g);
    float3 rgb = matrix * yuv;

    // Clamp to valid range
    rgb = saturate(rgb);

    // Write output
    outTexture.write(float4(rgb, 1.0), gid);
}

// MARK: - Combined Vertex/Fragment for YUV Display

// This allows direct YUV rendering without a separate compute pass

struct YUVVertexOut {
    float4 position [[position]];
    float2 texCoord;
};

vertex YUVVertexOut yuvDisplayVertex(
    uint vertexID [[vertex_id]],
    const device float4* vertices [[buffer(0)]],
    constant float4& transform [[buffer(1)]]
) {
    float4 vtx = vertices[vertexID];
    float2 position = vtx.xy;
    float2 texCoord = vtx.zw;

    float2 scale = transform.xy;
    float2 offset = transform.zw;

    YUVVertexOut out;
    out.position = float4(position * scale + offset, 0.0, 1.0);
    out.texCoord = texCoord;
    return out;
}

fragment float4 yuvDisplayFragment(
    YUVVertexOut in [[stage_in]],
    texture2d<float, access::sample> yTexture [[texture(0)]],
    texture2d<float, access::sample> cbcrTexture [[texture(1)]],
    sampler textureSampler [[sampler(0)]],
    constant YUVConversionParams& params [[buffer(0)]]
) {
    // Sample Y at full resolution
    float y = yTexture.sample(textureSampler, in.texCoord).r;

    // Sample CbCr (hardware handles interpolation for subsampled chroma)
    float2 cbcr = cbcrTexture.sample(textureSampler, in.texCoord).rg;

    // Handle 8-bit vs 10-bit, and video range vs full range.
    if (params.isTenBit != 0) {
        float y10 = (y * 65535.0) / 64.0;
        float2 cbcr10 = (cbcr * 65535.0) / 64.0;
        if (params.isVideoRange != 0) {
            y = (y10 - 64.0) / 876.0;
            cbcr = (cbcr10 - 512.0) / 896.0;
        } else {
            y = y10 / 1023.0;
            cbcr = (cbcr10 - 512.0) / 1023.0;
        }
    } else {
        if (params.isVideoRange != 0) {
            y = (y * 255.0 - 16.0) / 219.0;
            cbcr = (cbcr * 255.0 - 128.0) / 224.0;
        } else {
            cbcr = cbcr - 0.5;
        }
    }

    // Select color matrix and convert
    float3x3 matrix = params.useBT709 != 0 ? bt709Matrix : bt601Matrix;
    float3 yuv = float3(y, cbcr.r, cbcr.g);
    float3 rgb = matrix * yuv;

    return float4(saturate(rgb), 1.0);
}
