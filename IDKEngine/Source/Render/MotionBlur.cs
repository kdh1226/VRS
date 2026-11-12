using System;
using OpenTK.Mathematics;
using BBOpenGL;
using IDKEngine.Utils;

namespace IDKEngine.Render;

/// <summary>
/// Motion blur based on McGuire et al., "A Reconstruction Filter for Plausible Motion Blur" (I3D 2012):
/// TileMax -> NeighborMax -> Gather. Replaces the old single-pass velocity-streak blur.
/// </summary>
class MotionBlur : IDisposable
{
    // Must match TILE in the shaders. Max blur span = 2 * TILE_SIZE pixels.
    public const int TILE_SIZE = 16;

    public record struct GpuSettings
    {
        public int SampleCount = 12;
        public float Intensity = 1.0f;       // shutter scale (1.0 = one frame of motion at 60 FPS)
        public float MaxBlurPixels = 32.0f;  // total blur span, clamped to 2 * TILE_SIZE in the shader
        public float SoftZExtent = 0.05f;    // relative depth tolerance for foreground/background weights

        public GpuSettings()
        {
        }
    }

    public GpuSettings Settings;
    public BBG.Texture Result;

    private BBG.Texture tileMax;
    private BBG.Texture neighborMax;

    private readonly BBG.AbstractShaderProgram tileMaxProgram;
    private readonly BBG.AbstractShaderProgram neighborMaxProgram;
    private readonly BBG.AbstractShaderProgram gatherProgram;
    private readonly BBG.AbstractShaderProgram copyProgram;

    public MotionBlur(Vector2i size, in GpuSettings settings)
    {
        tileMaxProgram = new BBG.AbstractShaderProgram(BBG.AbstractShader.FromFile(BBG.ShaderStage.Compute, "MotionBlur/tileMax.glsl"));
        neighborMaxProgram = new BBG.AbstractShaderProgram(BBG.AbstractShader.FromFile(BBG.ShaderStage.Compute, "MotionBlur/neighborMax.glsl"));
        gatherProgram = new BBG.AbstractShaderProgram(BBG.AbstractShader.FromFile(BBG.ShaderStage.Compute, "MotionBlur/compute.glsl"));
        copyProgram = new BBG.AbstractShaderProgram(BBG.AbstractShader.FromFile(BBG.ShaderStage.Compute, "MotionBlur/copy.glsl"));

        SetSize(size);
        Settings = settings;
    }

    /// <summary>Blurs colorTexture and writes the result back into targetTexture (they may be the same texture).</summary>
    public void Compute(BBG.Texture colorTexture, BBG.Texture targetTexture)
    {
        const BBG.Cmd.MemoryBarrierMask barrier =
            BBG.Cmd.MemoryBarrierMask.TextureFetchBarrierBit | BBG.Cmd.MemoryBarrierMask.ShaderImageAccessBarrierBit;

        BBG.Computing.Compute("Compute MotionBlur", () =>
        {
            // 1) max blur vector per 16x16 tile
            BBG.Cmd.SetUniforms(Settings);
            BBG.Cmd.BindImageUnit(tileMax, 0);
            BBG.Cmd.UseShaderProgram(tileMaxProgram);
            BBG.Computing.Dispatch(tileMax.Width, tileMax.Height, 1); // one 16x16 workgroup per tile
            BBG.Cmd.MemoryBarrier(barrier);

            // 2) dominant vector of the 3x3 tile neighbourhood
            BBG.Cmd.BindImageUnit(neighborMax, 0);
            BBG.Cmd.BindTextureUnit(tileMax, 0);
            BBG.Cmd.UseShaderProgram(neighborMaxProgram);
            BBG.Computing.Dispatch(MyMath.DivUp(neighborMax.Width, 8), MyMath.DivUp(neighborMax.Height, 8), 1);
            BBG.Cmd.MemoryBarrier(barrier);

            // 3) depth/velocity aware gather: colorTexture -> Result
            BBG.Cmd.SetUniforms(Settings);
            BBG.Cmd.BindImageUnit(Result, 0);
            BBG.Cmd.BindTextureUnit(colorTexture, 0);
            BBG.Cmd.BindTextureUnit(neighborMax, 1);
            BBG.Cmd.UseShaderProgram(gatherProgram);
            BBG.Computing.Dispatch(MyMath.DivUp(Result.Width, 8), MyMath.DivUp(Result.Height, 8), 1);
            BBG.Cmd.MemoryBarrier(barrier);

            // 4) Result -> targetTexture
            BBG.Cmd.BindImageUnit(targetTexture, 0);
            BBG.Cmd.BindTextureUnit(Result, 0);
            BBG.Cmd.UseShaderProgram(copyProgram);
            BBG.Computing.Dispatch(MyMath.DivUp(targetTexture.Width, 8), MyMath.DivUp(targetTexture.Height, 8), 1);
            BBG.Cmd.MemoryBarrier(barrier);
        });
    }

    public void SetSize(Vector2i size)
    {
        if (Result != null) Result.Dispose();
        Result = new BBG.Texture(BBG.Texture.Type.Texture2D);
        Result.SetFilter(BBG.Sampler.MinFilter.Linear, BBG.Sampler.MagFilter.Linear);
        Result.SetWrapMode(BBG.Sampler.WrapMode.ClampToEdge, BBG.Sampler.WrapMode.ClampToEdge);
        Result.Allocate(size.X, size.Y, 1, BBG.Texture.InternalFormat.R16G16B16A16Float);

        int tilesX = MyMath.DivUp(size.X, TILE_SIZE);
        int tilesY = MyMath.DivUp(size.Y, TILE_SIZE);

        if (tileMax != null) tileMax.Dispose();
        tileMax = new BBG.Texture(BBG.Texture.Type.Texture2D);
        tileMax.SetFilter(BBG.Sampler.MinFilter.Nearest, BBG.Sampler.MagFilter.Nearest);
        tileMax.SetWrapMode(BBG.Sampler.WrapMode.ClampToEdge, BBG.Sampler.WrapMode.ClampToEdge);
        tileMax.Allocate(tilesX, tilesY, 1, BBG.Texture.InternalFormat.R16G16Float);

        if (neighborMax != null) neighborMax.Dispose();
        neighborMax = new BBG.Texture(BBG.Texture.Type.Texture2D);
        neighborMax.SetFilter(BBG.Sampler.MinFilter.Nearest, BBG.Sampler.MagFilter.Nearest);
        neighborMax.SetWrapMode(BBG.Sampler.WrapMode.ClampToEdge, BBG.Sampler.WrapMode.ClampToEdge);
        neighborMax.Allocate(tilesX, tilesY, 1, BBG.Texture.InternalFormat.R16G16Float);
    }

    public void Dispose()
    {
        Result.Dispose();
        tileMax.Dispose();
        neighborMax.Dispose();
        tileMaxProgram.Dispose();
        neighborMaxProgram.Dispose();
        gatherProgram.Dispose();
        copyProgram.Dispose();
    }
}
