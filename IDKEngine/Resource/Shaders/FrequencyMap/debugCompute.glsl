#version 460 core

layout(local_size_x = 16, local_size_y = 16, local_size_z = 1) in;

layout(binding = 0) restrict writeonly uniform image2D ImgResult;
layout(binding = 0) uniform sampler2D SamplerSrc;
layout(binding = 1) uniform usampler2D SamplerFrequencyMap;

const uint SHADING_RATE_1X1 = 0u;
const uint SHADING_RATE_2X2 = 1u;
const uint SHADING_RATE_4X4 = 2u;
const int TILE_SIZE = 16;

vec3 GetFrequencyColor(uint shadingRate)
{
    if (shadingRate == SHADING_RATE_1X1)
    {
        return vec3(1.0, 0.05, 0.05);
    }
    if (shadingRate == SHADING_RATE_2X2)
    {
        return vec3(1.0, 0.85, 0.0);
    }
    if (shadingRate == SHADING_RATE_4X4)
    {
        return vec3(0.05, 0.85, 0.1);
    }

    return vec3(0.2, 0.2, 1.0);
}

void main()
{
    ivec2 imgCoord = ivec2(gl_GlobalInvocationID.xy);
    ivec2 imgSize = imageSize(ImgResult);
    if (any(greaterThanEqual(imgCoord, imgSize)))
    {
        return;
    }

    ivec2 tileCoord = clamp(imgCoord / TILE_SIZE, ivec2(0), textureSize(SamplerFrequencyMap, 0) - ivec2(1));
    uint shadingRate = texelFetch(SamplerFrequencyMap, tileCoord, 0).r;

    vec3 srcColor = texelFetch(SamplerSrc, imgCoord, 0).rgb;
    vec3 debugColor = mix(srcColor, GetFrequencyColor(shadingRate), 0.55);

    ivec2 tileLocalCoordinate = imgCoord % TILE_SIZE;
    if (tileLocalCoordinate.x == 0 || tileLocalCoordinate.y == 0)
    {
        debugColor = vec3(0.0);
    }

    imageStore(ImgResult, imgCoord, vec4(debugColor, 1.0));
}
