using System;
using OpenTK.Mathematics;
using BBOpenGL;
using IDKEngine.Utils;

namespace IDKEngine.Render;

class FrequencyMap : IDisposable
{
    public record struct GpuSettings
    {
        public float MedDetailThreshold = 0.05f;
        public float LowDetailThreshold = 0.01f;
        public int VisualMode = 0; 

        public GpuSettings()
        {
        }
    }

    public GpuSettings Settings;
    public BBG.Texture Result; 

    private readonly BBG.AbstractShaderProgram shaderProgram;
    private readonly int tileSize = 16; 

    public FrequencyMap(Vector2i size, in GpuSettings settings)
    {
        shaderProgram = new BBG.AbstractShaderProgram(BBG.AbstractShader.FromFile(BBG.ShaderStage.Compute, "FrequencyMap/compute.glsl"));
        SetSize(size);
        Settings = settings;
    }

    public void Compute(BBG.Texture colorTexture, float edgeThreshold, float highRateRatio, float medRateRatio)
        {
            BBG.Computing.Compute("Compute FrequencyMap", () =>
            {
                BBG.Cmd.SetUniforms(Settings);
                
                // ▼▼▼ [추가] 셰이더로 엣지 비율 설정값 전송 ▼▼▼
                shaderProgram.Upload("EdgeThreshold", edgeThreshold);
                shaderProgram.Upload("HighRateRatio", highRateRatio);
                shaderProgram.Upload("MedRateRatio", medRateRatio);

                shaderProgram.Upload("VisualMode", Settings.VisualMode);

                BBG.Cmd.BindImageUnit(Result, 0);  
                BBG.Cmd.BindTextureUnit(colorTexture, 0);
                BBG.Cmd.UseShaderProgram(shaderProgram);

                BBG.Computing.Dispatch(MyMath.DivUp(Result.Width, 8), MyMath.DivUp(Result.Height, 8), 1);
                BBG.Cmd.MemoryBarrier(BBG.Cmd.MemoryBarrierMask.TextureFetchBarrierBit); // 진욱님 원본대로 유지!
            });
        }

    public void SetSize(Vector2i size)
    {
        if (Result != null) Result.Dispose();

        Result = new BBG.Texture(BBG.Texture.Type.Texture2D);
        Result.SetFilter(BBG.Sampler.MinFilter.Nearest, BBG.Sampler.MagFilter.Nearest);
        Result.SetWrapMode(BBG.Sampler.WrapMode.ClampToEdge, BBG.Sampler.WrapMode.ClampToEdge);
        
        int mapWidth = MyMath.DivUp(size.X, tileSize);
        int mapHeight = MyMath.DivUp(size.Y, tileSize);

        Result.Allocate(mapWidth, mapHeight, 1, BBG.Texture.InternalFormat.R8UInt); 
    }

    public void Dispose()
    {
        Result.Dispose();
        shaderProgram.Dispose();
    }

    public BBG.Rendering.ShadingRateNV[] ShadingRatePalette = new BBG.Rendering.ShadingRateNV[]
    {
        BBG.Rendering.ShadingRateNV._1InvocationPerPixel,
        BBG.Rendering.ShadingRateNV._1InvocationPer2x2Pixels,
        BBG.Rendering.ShadingRateNV._1InvocationPer4x4Pixels
    };

    public BBG.Rendering.VariableRateShadingNV GetRenderData()
    {
        return new BBG.Rendering.VariableRateShadingNV()
        {
            ShadingRateImage = Result,
            ShadingRatePalette = ShadingRatePalette,
        };
    }
}