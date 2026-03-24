#version 460 core

AppInclude(include/StaticUniformBuffers.glsl)

layout(local_size_x = 8, local_size_y = 8, local_size_z = 1) in;

layout(binding = 0) restrict writeonly uniform image2D ImgResult;
layout(binding = 0) uniform sampler2D SamplerSrc;

layout(std140, binding = 0) uniform SettingsUBO
{
    int   SampleCount;
    float Intensity;
    float MaxBlurPixels;
} settingsUBO;

void main()
{
    ivec2 imgCoord = ivec2(gl_GlobalInvocationID.xy);
    vec2  imgSize = vec2(imageSize(ImgResult));
    vec2  uv = (vec2(imgCoord) + 0.5) / imgSize;

    vec2 velocity = texelFetch(gBufferDataUBO.Velocity, imgCoord, 0).rg * 0.5;

    if (dot(velocity, velocity) < 1e-8)
    {
        imageStore(ImgResult, imgCoord, vec4(textureLod(SamplerSrc, uv, 0).rgb, 1.0));
        return;
    }

    float pixelLen = length(velocity * imgSize);
    if (pixelLen > settingsUBO.MaxBlurPixels)
    {
        velocity *= settingsUBO.MaxBlurPixels / pixelLen;
    }

    vec3  colorSum = vec3(0.0);
    float weightSum = 0.0;

    for (int i = 0; i < settingsUBO.SampleCount; i++)
    {
        float t = (float(i) / float(settingsUBO.SampleCount - 1)) - 0.5;
        vec2  sampleUV = clamp(uv + velocity * settingsUBO.Intensity * t, vec2(0.0), vec2(1.0));
        float weight = max(1.0 - abs(t) * 2.0 + (1.0 / float(settingsUBO.SampleCount)), 0.0);

        colorSum += textureLod(SamplerSrc, sampleUV, 0).rgb * weight;
        weightSum += weight;
    }

    imageStore(ImgResult, imgCoord, vec4(colorSum / weightSum, 1.0));
}