#version 460 core
#extension GL_KHR_shader_subgroup_arithmetic : require

AppInclude(include/StaticUniformBuffers.glsl)
AppInclude(ShadingRateClassification/include/Constants.glsl)

layout(local_size_x = TILE_SIZE, local_size_y = TILE_SIZE, local_size_z = 1) in;

layout(binding = 0) restrict writeonly uniform uimage2D ImgResult;
layout(binding = 1) restrict writeonly uniform image2D ImgDebug;
layout(binding = 2, r32ui) restrict writeonly uniform uimage2D ImgTemporalHistory;
layout(binding = 0) uniform sampler2D SamplerShaded;

layout(std140, binding = 0) uniform SettingsUBO
{
    ENUM_DEBUG_MODE DebugMode;
    float SpeedFactor;
    float LumVarianceFactor;
    float _Pad0;
    vec2 MousePos;
    int IsFoveated;
    int VrsMode;
    int IsMotionBlurVRS;
    int IsTemporalStabilization;
    int TemporalStableFrames;
    int TemporalHoldFrames;

    // Motion-adaptive VRS thresholds
    float MotionThresholdLow;
    float MotionThresholdHigh;
} settingsUBO;

layout(binding = 2) uniform usampler2D SamplerFrequencyMap;
layout(binding = 3) uniform usampler2D SamplerTemporalHistory;

const int ENUM_VRS_MODE_ORIGINAL = 0;
const int ENUM_VRS_MODE_FREQUENCY_MAP = 1;
const int ENUM_VRS_MODE_DISTANCE = 2;

uint GetFrequencyRate(uint frequencyRate);
uint GetDistanceRate(float linearDepth);
uint GetMotionAdaptiveRate(float meanSpeed);
uint ApplyTemporalStabilization(uint candidateRate);

uint ApplyTemporalStabilization(uint candidateRate)
{
    ivec2 tile = ivec2(gl_WorkGroupID.xy);
    uint previousState = texelFetch(SamplerTemporalHistory, tile, 0).r;
    bool hasHistory = (previousState & 0x80000000u) != 0u;

    uint appliedRate = previousState & 7u;
    uint pendingRate = (previousState >> 3u) & 7u;
    uint stableCount = (previousState >> 6u) & 255u;
    uint holdCount = (previousState >> 14u) & 255u;

    if (!hasHistory || settingsUBO.IsTemporalStabilization == 0)
    {
        appliedRate = candidateRate;
        pendingRate = candidateRate;
        stableCount = 0u;
        holdCount = 0u;
    }
    else if (holdCount > 0u)
    {
        holdCount--;
        pendingRate = candidateRate;
        stableCount = 0u;
    }
    else if (candidateRate == appliedRate)
    {
        pendingRate = candidateRate;
        stableCount = 0u;
    }
    else
    {
        if (candidateRate != pendingRate)
        {
            pendingRate = candidateRate;
            stableCount = 1u;
        }
        else
        {
            stableCount = min(stableCount + 1u, 255u);
        }

        uint requiredFrames = uint(max(settingsUBO.TemporalStableFrames, 1));
        if (stableCount >= requiredFrames)
        {
            appliedRate = candidateRate;
            pendingRate = candidateRate;
            stableCount = 0u;
            holdCount = uint(max(settingsUBO.TemporalHoldFrames, 0));
        }
    }

    uint newState = 0x80000000u |
        (appliedRate & 7u) |
        ((pendingRate & 7u) << 3u) |
        ((stableCount & 255u) << 6u) |
        ((holdCount & 255u) << 14u);
    imageStore(ImgTemporalHistory, tile, uvec4(newState));
    return appliedRate;
}
uint GetFrequencyRate(uint frequencyRate)
{
    if (frequencyRate == 0u) return ENUM_SHADING_RATE_1_INVOCATION_PER_PIXEL_NV;
    if (frequencyRate == 1u) return ENUM_SHADING_RATE_1_INVOCATION_PER_2X2_PIXELS_NV;
    return ENUM_SHADING_RATE_1_INVOCATION_PER_4X4_PIXELS_NV;
}

uint GetDistanceRate(float linearDepth)
{
    if (linearDepth > 35.0) return ENUM_SHADING_RATE_1_INVOCATION_PER_4X4_PIXELS_NV;
    if (linearDepth > 10.0) return ENUM_SHADING_RATE_1_INVOCATION_PER_2X2_PIXELS_NV;
    return ENUM_SHADING_RATE_1_INVOCATION_PER_PIXEL_NV;
}

uint GetMotionAdaptiveRate(float meanSpeed)
{
    if (meanSpeed < settingsUBO.MotionThresholdLow)
    {
        return ENUM_SHADING_RATE_1_INVOCATION_PER_PIXEL_NV;
    }

    if (meanSpeed < settingsUBO.MotionThresholdHigh)
    {
        return ENUM_SHADING_RATE_1_INVOCATION_PER_2X2_PIXELS_NV;
    }

    return ENUM_SHADING_RATE_1_INVOCATION_PER_4X4_PIXELS_NV;
}

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
        float linearDepth = (zNear * zFar) / max(0.0001, zFar - rawDepth * (zFar - zNear));

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

        uint finalRateValue = originalEngineRate;

        if (settingsUBO.VrsMode == ENUM_VRS_MODE_FREQUENCY_MAP)
        {
            uint frequencyRate = texelFetch(SamplerFrequencyMap, ivec2(gl_WorkGroupID.xy), 0).r;
            finalRateValue = GetFrequencyRate(frequencyRate);
        }
        else if (settingsUBO.VrsMode == ENUM_VRS_MODE_DISTANCE)
        {
            finalRateValue = GetDistanceRate(linearDepth);
        }

        // Apply motion-blur VRS after the selected base VRS mode.
        if (settingsUBO.IsMotionBlurVRS == 1)
        {
            // meanSpeed is the tile-average motion adjusted by DeltaRenderTime.
            uint motionRate = GetMotionAdaptiveRate(meanSpeed);

            // Select the coarser rate; larger values represent coarser shading.
            finalRateValue = max(finalRateValue, motionRate);            
        }

        if (settingsUBO.IsFoveated == 1)
        {
            vec2 normalizedPos = vec2(gl_WorkGroupID.xy) / vec2(gl_NumWorkGroups.xy);
            vec2 res = textureSize(SamplerShaded, 0);
            float aspect = res.x / res.y;
            vec2 diff = normalizedPos - settingsUBO.MousePos;
            diff.x *= aspect;
            float dist = length(diff);

            if (dist < 0.22) {
                finalRateValue = ENUM_SHADING_RATE_1_INVOCATION_PER_PIXEL_NV;
            } else if (dist < 0.38) {
                finalRateValue = min(finalRateValue, ENUM_SHADING_RATE_1_INVOCATION_PER_2X2_PIXELS_NV);
            }
        }
        else if (settingsUBO.IsFoveated == 2)
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
                finalRateValue = min(finalRateValue, ENUM_SHADING_RATE_1_INVOCATION_PER_2X2_PIXELS_NV);
            }
        }
        finalRateValue = ApplyTemporalStabilization(finalRateValue);
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
    return 0.2126 * color.x + 0.7152 * color.y + 0.0722 * color.z;
}
