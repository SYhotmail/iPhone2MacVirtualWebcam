#include <metal_stdlib>
using namespace metal;

// BT.601 coefficients for YUV to RGB conversion (used by most video sources)
constant float3 yuv2r = float3(1.164, 0.0, 1.596);
constant float3 yuv2g = float3(1.164, -0.392, -0.813);
constant float3 yuv2b = float3(1.164, 2.017, 0.0);

kernel void yuvToBGRA(
    texture2d<float, access::sample> yTexture [[texture(0)]],
    texture2d<float, access::sample> uvTexture [[texture(1)]],
    texture2d<float, access::write> outputTexture [[texture(2)]],
    uint2 gid [[thread_position_in_grid]]
) {
    if (gid.x >= outputTexture.get_width() || gid.y >= outputTexture.get_height()) {
        return;
    }

    constexpr sampler textureSampler(address::clamp_to_edge, filter::linear);
    const float2 size = float2(outputTexture.get_width(), outputTexture.get_height());
    const float2 uv = (float2(gid) + 0.5) / size;

    // Sample Y and UV planes
    float y = yTexture.sample(textureSampler, uv).r - 0.0625;
    float2 cbcr = uvTexture.sample(textureSampler, uv).rg - 0.5;

    // Convert YUV to RGB
    float3 yuv = float3(y, cbcr.x, cbcr.y);
    float r = dot(yuv, yuv2r);
    float g = dot(yuv, yuv2g);
    float b = dot(yuv, yuv2b);

    // Metal's bgra8Unorm format handles byte order - write as RGBA
    float4 rgba = float4(saturate(float3(r, g, b)), 1.0);
    outputTexture.write(rgba, gid);
}

kernel void compositePersonMask(
    texture2d<float, access::sample> sourceTexture [[texture(0)]],
    texture2d<float, access::sample> blurredTexture [[texture(1)]],
    texture2d<float, access::sample> maskTexture [[texture(2)]],
    texture2d<float, access::write> outputTexture [[texture(3)]],
    uint2 gid [[thread_position_in_grid]]
) {
    if (gid.x >= outputTexture.get_width() || gid.y >= outputTexture.get_height()) {
        return;
    }

    constexpr sampler textureSampler(address::clamp_to_edge, filter::linear);
    const float2 size = float2(outputTexture.get_width(), outputTexture.get_height());
    const float2 uv = (float2(gid) + 0.5) / size;

    const float4 sourceColor = sourceTexture.sample(textureSampler, uv);
    const float4 blurredColor = blurredTexture.sample(textureSampler, uv);
    const float mask = saturate(maskTexture.sample(textureSampler, uv).r);
    const float4 result = mix(blurredColor, sourceColor, mask);

    outputTexture.write(result, gid);
}

struct ScaleParams {
    float2 scale;
    float2 offset;
};

kernel void scaleAndCenter(
    texture2d<float, access::sample> sourceTexture [[texture(0)]],
    texture2d<float, access::write> outputTexture [[texture(1)]],
    constant ScaleParams& params [[buffer(0)]],
    uint2 gid [[thread_position_in_grid]]
) {
    if (gid.x >= outputTexture.get_width() || gid.y >= outputTexture.get_height()) {
        return;
    }

    const float2 pos = float2(gid) + 0.5;

    // Transform output position to source UV coordinates
    const float2 sourcePos = (pos - params.offset) / params.scale;
    const float2 sourceSize = float2(sourceTexture.get_width(), sourceTexture.get_height());
    const float2 uv = sourcePos / sourceSize;

    // Check if we're outside the source image bounds
    if (uv.x < 0.0 || uv.x > 1.0 || uv.y < 0.0 || uv.y > 1.0) {
        outputTexture.write(float4(0.0, 0.0, 0.0, 1.0), gid);
        return;
    }

    constexpr sampler textureSampler(address::clamp_to_edge, filter::linear);
    const float4 color = sourceTexture.sample(textureSampler, uv);
    outputTexture.write(color, gid);
}
