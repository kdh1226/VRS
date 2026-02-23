#version 460 core
#extension GL_KHR_shader_subgroup_arithmetic : require

AppInclude(include/StaticUniformBuffers.glsl)
AppInclude(ShadingRateClassification/include/Constants.glsl)

layout(local_size_x = TILE_SIZE, local_size_y = TILE_SIZE, local_size_z = 1) in;

layout(binding = 0) restrict writeonly uniform uimage2D ImgResult;
layout(binding = 1) restrict writeonly uniform image2D ImgDebug;
layout(binding = 0) uniform sampler2D SamplerShaded;

layout(std140, binding = 0) uniform SettingsUBO
{
    ENUM_DEBUG_MODE DebugMode;
    float SpeedFactor;
    float LumVarianceFactor;
    float _Pad0;
    vec2 MousePos;
    int IsFoveated;
} settingsUBO;

void GetTileData(vec3 color, vec2 velocity, out float speedSum, out float luminanceSum, out float luminanceSquaredSum);
float GetLuminance(vec3 color);

const uint SAMPLES_PER_TILE = TILE_SIZE * TILE_SIZE;

shared float SharedSpeedSums[64];
shared float SharedLumSums[64];
shared float SharedLumSquaredSums[64];

void main()
{
    ivec2 imgCoord = ivec2(gl_GlobalInvocationID.xy);
    vec2 velocity = texelFetch(gBufferDataUBO.Velocity, imgCoord, 0).rg;
    vec3 srcColor = texelFetch(SamplerShaded, imgCoord, 0).rgb;

    float speedSum, luminanceSum, luminanceSquaredSum;
    GetTileData(srcColor, velocity, speedSum, luminanceSum, luminanceSquaredSum);

    if (gl_LocalInvocationIndex == 0)
    {
        float meanSpeed = speedSum / SAMPLES_PER_TILE;
        meanSpeed /= perFrameDataUBO.DeltaRenderTime;

        float luminanceMean = luminanceSum / SAMPLES_PER_TILE;
        float luminanceSquaredMean = luminanceSquaredSum / SAMPLES_PER_TILE;

        float variance = max(0.0, luminanceSquaredMean - luminanceMean * luminanceMean);
        float stdDev = sqrt(variance);
        float coeffOfVariation = (luminanceMean > 0.001) ? (stdDev / luminanceMean) : 0.0;

        // [STEP 1] 무조건 기존 엔진 로직(LumVarianceFactor)으로 기본 화질을 계산합니다.
        uint originalEngineRate;
        if (luminanceMean <= 0.001)
        {
            originalEngineRate = ENUM_SHADING_RATE_1_INVOCATION_PER_4X4_PIXELS_NV;
        }
        else
        {
            float velocityShadingRate = mix(float(ENUM_SHADING_RATE_1_INVOCATION_PER_PIXEL_NV), float(ENUM_SHADING_RATE_1_INVOCATION_PER_4X4_PIXELS_NV), meanSpeed * settingsUBO.SpeedFactor);
            float varianceShadingRate = mix(float(ENUM_SHADING_RATE_1_INVOCATION_PER_PIXEL_NV), float(ENUM_SHADING_RATE_1_INVOCATION_PER_4X4_PIXELS_NV), settingsUBO.LumVarianceFactor / coeffOfVariation);

            float combinedShadingRate = velocityShadingRate + varianceShadingRate;
            originalEngineRate = uint(clamp(round(combinedShadingRate), float(ENUM_SHADING_RATE_1_INVOCATION_PER_PIXEL_NV), float(ENUM_SHADING_RATE_1_INVOCATION_PER_4X4_PIXELS_NV)));
        }

        uint finalRateValue;

        // [STEP 2] 포비티드 스위치와 결합 (하이브리드)
        if (settingsUBO.IsFoveated == 1)
        {
            vec2 normalizedPos = vec2(gl_WorkGroupID.xy) / vec2(gl_NumWorkGroups.xy);
            float dist = distance(normalizedPos, settingsUBO.MousePos);

            if (dist < 0.15)
            {
                // 마우스 근처(시선 집중 영역): 무슨 일이 있어도 최고화질(1x1) 유지!
                finalRateValue = ENUM_SHADING_RATE_1_INVOCATION_PER_PIXEL_NV;
            }
            else
            {
                // 마우스 바깥 영역: 엔진이 지능적으로 판단한(슬라이더 적용된) 화질을 사용!
                finalRateValue = originalEngineRate;
            }
        }
        else
        {
            // 스위치를 끄면 그냥 순수 엔진 로직
            finalRateValue = originalEngineRate;
        }

        imageStore(ImgResult, ivec2(gl_WorkGroupID.xy), uvec4(finalRateValue));

        if (settingsUBO.DebugMode == ENUM_DEBUG_MODE_SPEED)
            imageStore(ImgDebug, ivec2(gl_WorkGroupID.xy), vec4(meanSpeed));
        else if (settingsUBO.DebugMode == ENUM_DEBUG_MODE_LUMINANCE)
            imageStore(ImgDebug, ivec2(gl_WorkGroupID.xy), vec4(luminanceMean));
        else if (settingsUBO.DebugMode == ENUM_DEBUG_MODE_LUMINANCE_VARIANCE)
            imageStore(ImgDebug, ivec2(gl_WorkGroupID.xy), vec4(coeffOfVariation));
    }
}

void GetTileData(vec3 color, vec2 velocity, out float speedSum, out float luminanceSum, out float luminanceSquaredSum)
{
    float luminance = GetLuminance(color);
    float subgroupAddedSpeed = subgroupAdd(length(velocity));
    float subgroupAddedLum = subgroupAdd(luminance);
    float subgroupAddedSquaredLum = subgroupAdd(luminance * luminance);
    if (subgroupElect())
    {
        SharedSpeedSums[gl_SubgroupID] = subgroupAddedSpeed;
        SharedLumSums[gl_SubgroupID] = subgroupAddedLum;
        SharedLumSquaredSums[gl_SubgroupID] = subgroupAddedSquaredLum;
    }
    barrier();
    if (gl_LocalInvocationIndex == 0)
    {
        for (int i = 1; i < gl_NumSubgroups; i++)
        {
            SharedSpeedSums[0] += SharedSpeedSums[i];
            SharedLumSums[0] += SharedLumSums[i];
            SharedLumSquaredSums[0] += SharedLumSquaredSums[i];
        }
    }
    barrier();
    speedSum = SharedSpeedSums[0];
    luminanceSum = SharedLumSums[0];
    luminanceSquaredSum = SharedLumSquaredSums[0];
}

float GetLuminance(vec3 color)
{
    return (color.x + color.y + color.z) * (1.0 / 3.0);
}

