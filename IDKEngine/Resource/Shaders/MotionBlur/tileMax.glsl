#version 460 core

// Pass 1/4 of the McGuire-style motion blur (TileMax).
// One 16x16 workgroup per tile: finds the blur vector (in pixels) with the largest
// magnitude inside the tile. TILE must equal the max blur radius (MaxBlurPixels / 2).

AppInclude(include/StaticUniformBuffers.glsl)

#define TILE 16
layout(local_size_x = TILE, local_size_y = TILE, local_size_z = 1) in;

layout(binding = 0) restrict writeonly uniform image2D ImgTileMax;

layout(std140, binding = 0) uniform SettingsUBO
{
    int   SampleCount;
    float Intensity;
    float MaxBlurPixels;
    float SoftZExtent;
} settingsUBO;

shared vec2 SharedVelocity[TILE * TILE];

// Blur vector in pixels: total blur span of this pixel over the exposure.
vec2 GetBlurVector(ivec2 coord, vec2 imgSize)
{
    vec2 v = texelFetch(gBufferDataUBO.Velocity, coord, 0).rg * 0.5; // NDC delta -> UV delta
    v /= perFrameDataUBO.DeltaRenderTime;
    v *= 0.016;                                                      // normalise to 60 FPS exposure
    v *= settingsUBO.Intensity;

    vec2 px = v * imgSize;
    float maxSpan = min(settingsUBO.MaxBlurPixels, 2.0 * float(TILE));
    float len = length(px);
    if (len > maxSpan)
    {
        px *= maxSpan / len;
    }
    return px;
}

void main()
{
    ivec2 texSize = textureSize(gBufferDataUBO.Velocity, 0);
    ivec2 coord = min(ivec2(gl_GlobalInvocationID.xy), texSize - ivec2(1));

    SharedVelocity[gl_LocalInvocationIndex] = GetBlurVector(coord, vec2(texSize));
    barrier();

    for (uint stride = (TILE * TILE) / 2u; stride > 0u; stride >>= 1u)
    {
        if (gl_LocalInvocationIndex < stride)
        {
            vec2 a = SharedVelocity[gl_LocalInvocationIndex];
            vec2 b = SharedVelocity[gl_LocalInvocationIndex + stride];
            SharedVelocity[gl_LocalInvocationIndex] = dot(b, b) > dot(a, a) ? b : a;
        }
        barrier();
    }

    if (gl_LocalInvocationIndex == 0u)
    {
        imageStore(ImgTileMax, ivec2(gl_WorkGroupID.xy), vec4(SharedVelocity[0], 0.0, 0.0));
    }
}
