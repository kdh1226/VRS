#version 460 core

// Pass 4/4: copy the blurred result back into the pipeline texture.
// (OpenGL has no safe in-place read+write of the same texture in a compute pass.)

layout(local_size_x = 8, local_size_y = 8, local_size_z = 1) in;

layout(binding = 0) restrict writeonly uniform image2D ImgDst;
layout(binding = 0) uniform sampler2D SamplerSrc;

void main()
{
    ivec2 c = ivec2(gl_GlobalInvocationID.xy);
    if (any(greaterThanEqual(c, imageSize(ImgDst))))
    {
        return;
    }
    imageStore(ImgDst, c, texelFetch(SamplerSrc, c, 0));
}
