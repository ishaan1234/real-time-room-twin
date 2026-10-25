// Full-screen camera image behind the mesh.

#include <metal_stdlib>
#include "../Reconstruction/MetalCommon.h"

using namespace metal;

struct CameraFragmentIn {
    float4 position [[position]];
    float2 uv;
};

vertex CameraFragmentIn cameraVertex(uint vid [[vertex_id]],
                                     constant float2* uvs [[buffer(0)]]) {
    const float2 positions[4] = {float2(-1, -1), float2(1, -1), float2(-1, 1), float2(1, 1)};
    CameraFragmentIn out;
    out.position = float4(positions[vid], 0.0, 1.0);
    out.uv = uvs[vid];
    return out;
}

fragment float4 cameraFragment(CameraFragmentIn in [[stage_in]],
                               texture2d<float> y [[texture(0)]],
                               texture2d<float> cbcr [[texture(1)]]) {
    constexpr sampler s(filter::linear, address::clamp_to_edge);
    return float4(ycbcrToRGB(y.sample(s, in.uv).r, cbcr.sample(s, in.uv).rg), 1.0);
}
