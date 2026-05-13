#version 460 core

layout(local_size_x = 16, local_size_y = 16, local_size_z = 1) in;

layout(binding = 0) uniform sampler2D inputTexture;
layout(binding = 0, r8ui) uniform writeonly uimage2D resultImage;

uniform float EdgeThreshold;
uniform float HighRateRatio;
uniform float MedRateRatio;
shared uint SharedEdgeCounts[256];
shared uint SharedSampleCounts[256];

float GetSurfaceData(ivec2 coord, ivec2 texSize) {
    coord = clamp(coord, ivec2(0), texSize - ivec2(1));
    vec2 normalXY = texelFetch(inputTexture, coord, 0).rg;
    return normalXY.x + normalXY.y;
}

void main() {
    ivec2 tileID = ivec2(gl_WorkGroupID.xy);
    ivec2 localID = ivec2(gl_LocalInvocationID.xy);
    ivec2 texSize = textureSize(inputTexture, 0);
    ivec2 tileCount = imageSize(resultImage);
    uint localIndex = gl_LocalInvocationIndex;

    if(tileID.x >= tileCount.x || tileID.y >= tileCount.y) return;

    ivec2 baseCoord = tileID * 16;
    ivec2 pixelCoord = baseCoord + localID;
    bool validSample = all(lessThan(pixelCoord, texSize));

    uint edgeCount = 0u;
    if(validSample) {
        float p00 = GetSurfaceData(pixelCoord + ivec2(-1, -1), texSize);
        float p10 = GetSurfaceData(pixelCoord + ivec2( 0, -1), texSize);
        float p20 = GetSurfaceData(pixelCoord + ivec2( 1, -1), texSize);
        float p01 = GetSurfaceData(pixelCoord + ivec2(-1,  0), texSize);
        float p21 = GetSurfaceData(pixelCoord + ivec2( 1,  0), texSize);
        float p02 = GetSurfaceData(pixelCoord + ivec2(-1,  1), texSize);
        float p12 = GetSurfaceData(pixelCoord + ivec2( 0,  1), texSize);
        float p22 = GetSurfaceData(pixelCoord + ivec2( 1,  1), texSize);

        float gx = -p00 + p20 - 2.0 * p01 + 2.0 * p21 - p02 + p22;
        float gy = -p00 - 2.0 * p10 - p20 + p02 + 2.0 * p12 + p22;
        float gradient = abs(gx) + abs(gy);

        edgeCount = gradient > EdgeThreshold ? 1u : 0u;
    }

    SharedEdgeCounts[localIndex] = edgeCount;
    SharedSampleCounts[localIndex] = validSample ? 1u : 0u;
    barrier();

    for(uint stride = 128u; stride > 0u; stride >>= 1u) {
        if(localIndex < stride) {
            SharedEdgeCounts[localIndex] += SharedEdgeCounts[localIndex + stride];
            SharedSampleCounts[localIndex] += SharedSampleCounts[localIndex + stride];
        }
        barrier();
    }

    if(localIndex != 0u) return;

    float edgeRatio = SharedSampleCounts[0] > 0u ? float(SharedEdgeCounts[0]) / float(SharedSampleCounts[0]) : 0.0;

    uint hwRate = 6u;
    uint visRate = 64u;

    if(edgeRatio > HighRateRatio) {
        hwRate = 0u;
        visRate = 255u;
    }
    else if(edgeRatio > MedRateRatio) {
        hwRate = 3u;
        visRate = 128u;
    }

    imageStore(resultImage, tileID, uvec4(hwRate, 0u, 0u, 0u));
}
