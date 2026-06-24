#include <metal_stdlib>
using namespace metal;

struct DepthPackUniforms {
    float minDepth;
    float maxDepth;
    uint invalidValue;
};

kernel void packDepthFloat32ToYUV10(
    texture2d<float, access::read> depthTexture [[texture(0)]],
    texture2d<ushort, access::write> yTexture [[texture(1)]],
    texture2d<ushort, access::write> cbcrTexture [[texture(2)]],
    constant DepthPackUniforms& uniforms [[buffer(0)]],
    uint2 gid [[thread_position_in_grid]]
) {
    uint width = depthTexture.get_width();
    uint height = depthTexture.get_height();
    if (gid.x >= width || gid.y >= height) {
        return;
    }

    float depth = depthTexture.read(gid).r;
    float range = max(uniforms.maxDepth - uniforms.minDepth, FLT_MIN);
    ushort quantized = ushort(uniforms.invalidValue);
    if (isfinite(depth) && depth > uniforms.minDepth) {
        float normalized = clamp((depth - uniforms.minDepth) / range, 0.0f, 1.0f);
        quantized = max(ushort(round(normalized * 1023.0f)), ushort(1));
    }
    yTexture.write(ushort(quantized << 6), gid);

    if ((gid.x & 1u) == 0u && (gid.y & 1u) == 0u) {
        uint2 chromaGid = gid / 2u;
        if (chromaGid.x < cbcrTexture.get_width() && chromaGid.y < cbcrTexture.get_height()) {
            ushort neutral = ushort(512u << 6);
            cbcrTexture.write(ushort4(neutral, neutral, 0, 0), chromaGid);
        }
    }
}
