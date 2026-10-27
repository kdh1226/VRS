#version 460 core

// Pass 2/4 of the McGuire-style motion blur (NeighborMax).
// For every tile take the dominant blur vector of its 3x3 tile neighbourhood,
// because blur from a neighbouring tile can reach into this one.

layout(local_size_x = 8, local_size_y = 8, local_size_z = 1) in;

layout(binding = 0) restrict writeonly uniform image2D ImgNeighborMax;
layout(binding = 0) uniform sampler2D SamplerTileMax;

void main()
{
    ivec2 tile = ivec2(gl_GlobalInvocationID.xy);
    ivec2 tileCount = textureSize(SamplerTileMax, 0);
    if (any(greaterThanEqual(tile, tileCount)))
    {
        return;
    }

    vec2 best = vec2(0.0);
    for (int dy = -1; dy <= 1; dy++)
    {
        for (int dx = -1; dx <= 1; dx++)
        {
            ivec2 c = clamp(tile + ivec2(dx, dy), ivec2(0), tileCount - ivec2(1));
            vec2 v = texelFetch(SamplerTileMax, c, 0).rg;
            if (dot(v, v) > dot(best, best))
            {
                best = v;
            }
        }
    }

    imageStore(ImgNeighborMax, tile, vec4(best, 0.0, 0.0));
}
