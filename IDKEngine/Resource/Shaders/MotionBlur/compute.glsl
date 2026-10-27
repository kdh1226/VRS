#version 460 core

// Pass 3/4 of the McGuire-style motion blur (reconstruction filter / gather).
// Based on: McGuire, Hennessy, Bukowski, Osman,
//   "A Reconstruction Filter for Plausible Motion Blur", I3D 2012.
// Reads SamplerSrc, writes ImgResult (must be a DIFFERENT texture: no in-place blur).

AppInclude(include/StaticUniformBuffers.glsl)

#define TILE 16
layout(local_size_x = 8, local_size_y = 8, local_size_z = 1) in;

layout(binding = 0) restrict writeonly uniform image2D ImgResult;
layout(binding = 0) uniform sampler2D SamplerSrc;
layout(binding = 1) uniform sampler2D SamplerNeighborMax;

layout(std140, binding = 0) uniform SettingsUBO
{
    int   SampleCount;
    float Intensity;
    float MaxBlurPixels;
    float SoftZExtent;   // relative depth tolerance, e.g. 0.05 = 5 %
} settingsUBO;

vec2 GetBlurVector(ivec2 coord, vec2 imgSize)
{
    vec2 v = texelFetch(gBufferDataUBO.Velocity, coord, 0).rg * 0.5;
    v /= perFrameDataUBO.DeltaRenderTime;
    v *= 0.016;
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

float LinearizeDepth(float rawDepth)
{
    float zNear = perFrameDataUBO.NearPlane;
    float zFar = perFrameDataUBO.FarPlane;
    return (zNear * zFar) / max(0.0001, zFar - rawDepth * (zFar - zNear));
}

// 1 when zA is in front of (or equal to) zB, fading to 0 when zA is behind zB by more than the extent.
float SoftDepthCompare(float zA, float zB)
{
    float extent = max(settingsUBO.SoftZExtent * 0.5 * (zA + zB), 1e-4);
    return clamp(1.0 - (zA - zB) / extent, 0.0, 1.0);
}

float Cone(float dist, float radius)
{
    return clamp(1.0 - dist / max(radius, 1e-4), 0.0, 1.0);
}

float Cylinder(float dist, float radius)
{
    radius = max(radius, 1e-3); // smoothstep is undefined when both edges are equal
    return 1.0 - smoothstep(0.95 * radius, 1.05 * radius, dist);
}

float InterleavedGradientNoise(vec2 p)
{
    return fract(52.9829189 * fract(dot(p, vec2(0.06711056, 0.00583715))));
}

void main()
{
    ivec2 imgCoord = ivec2(gl_GlobalInvocationID.xy);
    ivec2 size = imageSize(ImgResult);
    if (any(greaterThanEqual(imgCoord, size)))
    {
        return;
    }
    vec2 imgSize = vec2(size);

    vec3 centerColor = texelFetch(SamplerSrc, imgCoord, 0).rgb;

    // Dominant blur vector around this pixel (pixels, total span).
    vec2 vn = texelFetch(SamplerNeighborMax, imgCoord / TILE, 0).rg;
    float vnLen = length(vn);
    if (vnLen < 0.5)
    {
        imageStore(ImgResult, imgCoord, vec4(centerColor, 1.0));
        return;
    }

    vec2 vc = GetBlurVector(imgCoord, imgSize);
    float vcLen = length(vc);
    float zc = LinearizeDepth(texelFetch(gBufferDataUBO.Depth, imgCoord, 0).r);

    int S = max(settingsUBO.SampleCount, 3);
    float jitter = InterleavedGradientNoise(vec2(imgCoord)) - 0.5;

    // Centre sample: the sharper the pixel itself (small vc), the more it keeps its own colour.
    float centerWeight = float(S) / (2.0 * max(vcLen, 1.0));
    vec3 colorSum = centerColor * centerWeight;
    float weightSum = centerWeight;

    for (int i = 0; i < S; i++)
    {
        float t = (float(i) + 0.5 + jitter) / float(S) - 0.5;   // jittered, in [-0.5, 0.5]
        vec2 offsetPx = vn * t;
        float dist = length(offsetPx);
        if (dist < 0.5)
        {
            continue;
        }

        ivec2 yCoord = clamp(imgCoord + ivec2(round(offsetPx)), ivec2(0), size - ivec2(1));

        vec2 vy = GetBlurVector(yCoord, imgSize);
        float vyLen = length(vy);
        float zy = LinearizeDepth(texelFetch(gBufferDataUBO.Depth, yCoord, 0).r);

        float foreground = SoftDepthCompare(zy, zc); // Y in front of X: Y's blur may cover X
        float background = SoftDepthCompare(zc, zy); // X in front of Y: X's own blur covers Y

        float alpha =
            foreground * Cone(dist, 0.5 * vyLen) +
            background * Cone(dist, 0.5 * vcLen) +
            Cylinder(dist, 0.5 * vyLen) * Cylinder(dist, 0.5 * vcLen) * 2.0;

        colorSum += texelFetch(SamplerSrc, yCoord, 0).rgb * alpha;
        weightSum += alpha;
    }

    imageStore(ImgResult, imgCoord, vec4(colorSum / weightSum, 1.0));
}
