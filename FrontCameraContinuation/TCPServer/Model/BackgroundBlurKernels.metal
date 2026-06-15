#include <metal_stdlib>
using namespace metal;

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
