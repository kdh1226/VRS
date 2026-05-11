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

    int IsDistanceVRS;
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

        ivec2 tileCenter = ivec2(gl_WorkGroupID.xy * TILE_SIZE + (TILE_SIZE / 2));
        float rawDepth = texelFetch(gBufferDataUBO.Depth, tileCenter, 0).r;
        
        float zNear = perFrameDataUBO.NearPlane;
        float zFar = perFrameDataUBO.FarPlane;
        float ndc = rawDepth * 2.0 - 1.0;

        float linearDepth = (2.0 * zNear * zFar) / (zFar + zNear - ndc * (zFar - zNear));

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

        // 1단계: 화면 전체에 깔릴 '배경 화질'을 거리 기반으로 먼저 계산합니다.
        uint backgroundRate = originalEngineRate;
        if (settingsUBO.IsDistanceVRS == 1)
        {
            if (linearDepth > 30.0) 
            {
                if (backgroundRate < ENUM_SHADING_RATE_1_INVOCATION_PER_2X2_PIXELS_NV) {
                    backgroundRate = ENUM_SHADING_RATE_1_INVOCATION_PER_2X2_PIXELS_NV;
                }
            }
            if (linearDepth > 80.0) 
            {
                backgroundRate = ENUM_SHADING_RATE_1_INVOCATION_PER_4X4_PIXELS_NV;
            }
            if (coeffOfVariation > 0.05) 
            {
                backgroundRate = ENUM_SHADING_RATE_1_INVOCATION_PER_PIXEL_NV;
            }
        }

        // 2단계: 계산된 거리 기반 배경 위에 스코프/마우스의 초고화질 영역을 뚫어줍니다.
        if (settingsUBO.IsFoveated == 1) // 마우스 모드
        {
            vec2 normalizedPos = vec2(gl_WorkGroupID.xy) / vec2(gl_NumWorkGroups.xy);
            vec2 res = textureSize(SamplerShaded, 0); 
            float aspect = res.x / res.y;
            vec2 diff = normalizedPos - settingsUBO.MousePos;
            diff.x *= aspect;
            float dist = length(diff);
            
            if (dist < 0.15) {
                finalRateValue = ENUM_SHADING_RATE_1_INVOCATION_PER_PIXEL_NV;
            } else {
                finalRateValue = backgroundRate; // 무조건 4x4 대신 똑똑한 배경 할당!
            }
        }
        else if (settingsUBO.IsFoveated == 2) // 스코프 모드
        {
            vec2 normalizedPos = vec2(gl_WorkGroupID.xy) / vec2(gl_NumWorkGroups.xy);
            vec2 diff = normalizedPos - vec2(0.5, 0.5);
            vec2 res = textureSize(SamplerShaded, 0); 
            float aspect = res.x / res.y;
            diff.x *= aspect; 
            
            float circularDist = length(diff);

            if (circularDist < 0.45) {
                finalRateValue = ENUM_SHADING_RATE_1_INVOCATION_PER_PIXEL_NV;
            } else {
                finalRateValue = ENUM_SHADING_RATE_1_INVOCATION_PER_4X4_PIXELS_NV;               
            }
        }
        else // 포비티드가 꺼져있을 때 (일반 화면)
        {
            finalRateValue = backgroundRate;
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

