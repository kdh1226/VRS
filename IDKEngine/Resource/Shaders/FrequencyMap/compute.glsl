#version 460 core

layout(local_size_x = 8, local_size_y = 8, local_size_z = 1) in;

layout(binding = 0) uniform sampler2D inputTexture;
layout(binding = 0, r8ui) uniform writeonly uimage2D resultImage;

uniform float EdgeThreshold;
uniform float HighRateRatio;
uniform float MedRateRatio;
uniform int VisualMode;

float GetSurfaceData(vec2 uv) {
    vec2 normalXY = texture(inputTexture, uv).rg;
    return normalXY.x + normalXY.y; 
}

void main() {
    ivec2 tileID = ivec2(gl_GlobalInvocationID.xy);
    ivec2 texSize = textureSize(inputTexture, 0);
    ivec2 tileCount = texSize / 16;

    if(tileID.x >= tileCount.x || tileID.y >= tileCount.y) return;

    ivec2 baseCoord = tileID * 16;
    vec2 texelSize = 1.0 / vec2(texSize);

    int edgeCount = 0;

    for(int y = 0; y < 16; y++) {
        for(int x = 0; x < 16; x++) {
            vec2 uv = (vec2(baseCoord + ivec2(x, y)) + 0.5) * texelSize;

            float p00 = GetSurfaceData(uv + vec2(-texelSize.x, -texelSize.y));
            float p10 = GetSurfaceData(uv + vec2(0.0,          -texelSize.y));
            float p20 = GetSurfaceData(uv + vec2( texelSize.x, -texelSize.y));
            float p01 = GetSurfaceData(uv + vec2(-texelSize.x,  0.0));
            float p21 = GetSurfaceData(uv + vec2( texelSize.x,  0.0));
            float p02 = GetSurfaceData(uv + vec2(-texelSize.x,  texelSize.y));
            float p12 = GetSurfaceData(uv + vec2(0.0,           texelSize.y));
            float p22 = GetSurfaceData(uv + vec2( texelSize.x,  texelSize.y));

            float gx = -p00 + p20 - 2.0 * p01 + 2.0 * p21 - p02 + p22;
            float gy = -p00 - 2.0 * p10 - p20 + p02 + 2.0 * p12 + p22;

            float gradient = abs(gx) + abs(gy);

            if(gradient > EdgeThreshold) {
                edgeCount++;
            }
        }
    }

    float edgeRatio = float(edgeCount) / 256.0;

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

    uint finalRate = (VisualMode == 1) ? visRate : hwRate;

    imageStore(resultImage, tileID, uvec4(finalRate, 0u, 0u, 0u));
}