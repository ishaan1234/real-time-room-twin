// Draws the reconstructed mesh straight from the vertex and triangle pools.
// Unused triangle slots are (0, 0, 0) and rasterize to nothing.

#include <metal_stdlib>
#include "ShaderTypes.h"

using namespace metal;

struct MeshFragmentIn {
    float4 position [[position]];
    float3 world;
    float3 color;
};

vertex MeshFragmentIn meshVertex(uint vid [[vertex_id]],
                                 device const MeshVertex* vertices [[buffer(0)]],
                                 constant MeshUniforms& u [[buffer(1)]]) {
    MeshVertex v = vertices[vid];
    float3 p = float3(v.position[0], v.position[1], v.position[2]);
    MeshFragmentIn out;
    out.position = u.viewProjection * float4(p, 1.0);
    out.world = p;
    out.color = unpack_unorm4x8_to_float(v.color).rgb;
    return out;
}

fragment float4 meshFragment(MeshFragmentIn in [[stage_in]],
                             constant MeshUniforms& u [[buffer(0)]]) {
    if (in.world.y > u.clipHeight) discard_fragment();
    // Flat normal from screen-space derivatives; no per-vertex normals needed.
    float3 n = normalize(cross(dfdx(in.world), dfdy(in.world)));
    float facing = fabs(dot(n, normalize(u.cameraPosition.xyz - in.world)));
    if (u.mode == RT_MESH_MODE_SHADED) {
        return float4(float3(0.9) * (0.15 + 0.85 * facing), 1.0);
    }
    return float4(in.color * (0.6 + 0.4 * facing), 1.0);
}

struct RoomGuideOut {
    float4 position [[position]];
};

vertex RoomGuideOut roomGuideVertex(uint vid [[vertex_id]],
                                    constant float4* positions [[buffer(0)]],
                                    constant MeshUniforms& u [[buffer(1)]]) {
    RoomGuideOut out;
    out.position = u.viewProjection * positions[vid];
    return out;
}

fragment float4 roomGuideFragment(RoomGuideOut in [[stage_in]],
                                  constant float4& color [[buffer(0)]]) {
    return color;
}
