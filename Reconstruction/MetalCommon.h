// Metal-only helpers shared by several shader files.

#ifndef MetalCommon_h
#define MetalCommon_h

#include <metal_stdlib>

// ARKit's captured image is full-range BT.601 YCbCr.
inline metal::float3 ycbcrToRGB(float y, metal::float2 cbcr) {
    float cb = cbcr.x - 0.5;
    float cr = cbcr.y - 0.5;
    return metal::saturate(metal::float3(y + 1.402 * cr,
                                         y - 0.344136 * cb - 0.714136 * cr,
                                         y + 1.772 * cb));
}

#endif
