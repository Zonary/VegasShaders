//Contrast Adaptive Sharpening Enhanced Shader for TESReloaded
//----------------------------------------------------
// Features:
// - Exponential Depth falloff
// 		Simple depth falloff using a max depth var to calculate a 0-1 fallOffFactor that's then lerped with the final sharpened color
//		Multipied by 1000 so you have to use lower input params making 0 apply no effect and 1 equal 1000
// - Intensity
//		It does what it says, intensity param that's multiplied by the contrast to increase overall sharpening effect
//		Multipied by two so the effect is more noticable.
// - Adjustable Kernel size
//		You just change the kernel size to increase sampling radius of the custom Manhattan sampling thingy
// - Debug modes
//		Used for dev mode so you can see each process of the sharpening
//----------------------------------------------------

#define debugMode 0 // 1 - FalloffFactor 2 - Contrast 3 - Average(blur)
#define falloffExponent 4 // Set the falloff exponent to control the curve steepness for depth falloff
#define kernelSize 3 // Set kernel size for averaging, to find total samples multiply the number by it's self

float4 TESR_SharpeningData; // X - Intensity Y - Clamp  Z - Offset(depth falloff) W - 1 = CAS (2026-11-13)
float4 TESR_ReciprocalResolution;

sampler2D TESR_RenderedBuffer : register(s0) = sampler_state { ADDRESSU = CLAMP; ADDRESSV = CLAMP; MAGFILTER = LINEAR; MINFILTER = LINEAR; MIPFILTER = LINEAR; };
sampler2D TESR_DepthBuffer : register(s1) = sampler_state { ADDRESSU = CLAMP; ADDRESSV = CLAMP; MAGFILTER = LINEAR; MINFILTER = LINEAR; MIPFILTER = LINEAR; };

#include "Includes/Helpers.hlsl"
#include "Includes/Depth.hlsl"

struct VSOUT
{
    float4 vertPos : POSITION;
    float2 UVCoord : TEXCOORD0;
};

struct VSIN
{
    float4 vertPos : POSITION0;
    float2 UVCoord : TEXCOORD0;
};

VSOUT FrameVS(VSIN IN)
{
    VSOUT OUT = (VSOUT) 0.0f;
    OUT.vertPos = IN.vertPos;
    OUT.UVCoord = IN.UVCoord;
    return (OUT);
}

// UNOFFICIAL 2026-11-13 (ported from a tester fork, default off) [Shaders.Sharpening.Main] CAS: AMD FidelityFX Contrast Adaptive
// Sharpening (the non-scaling filter with CAS_BETTER_DIAGONALS) with the same depth falloff, in place of the filter below (TESR_SharpeningData.w 1).
// Ported from ffx_cas.h (FidelityFX CAS, https://github.com/GPUOpen-Effects/FidelityFX-CAS):
//   Copyright (c) 2017-2019 Advanced Micro Devices, Inc. All rights reserved.
//   Permission is hereby granted, free of charge, to any person obtaining a copy of this software and associated documentation
//   files (the "Software"), to deal in the Software without restriction, including without limitation the rights to use, copy,
//   modify, merge, publish, distribute, sublicense, and/or sell copies of the Software, and to permit persons to whom the Software
//   is furnished to do so, subject to the following conditions:
//   The above copyright notice and this permission notice shall be included in all copies or substantial portions of the Software.
//   THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES
//   OF MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT HOLDERS BE
//   LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM, OUT OF OR IN
//   CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE SOFTWARE.
// CAS: a 3x3 neighbourhood; the soft minimum and maximum of the cross (b d e f h) and of the full 3x3 give how much headroom the pixel
// has before it would clip ("amp"); the four cross neighbours get a negative weight w = amp * peak, so low-contrast detail is sharpened
// more and strong edges are left nearly alone (no halos). One weight for all three channels (green's, as AMD's default path).
float3 CasTap(float2 uv, float2 offset)
{
    return tex2Dlod(TESR_RenderedBuffer, float4(uv + offset * TESR_ReciprocalResolution.xy, 0.0, 0.0)).rgb;
}

float4 CasSharpen(float2 uv)
{
    float4 color = tex2Dlod(TESR_RenderedBuffer, float4(uv, 0.0, 0.0));
    const float maxDepth = TESR_SharpeningData.z * 1000.0;
    if (maxDepth <= 0.0) return color;
    const float falloff = pow(saturate((maxDepth - readDepthLod(uv)) / maxDepth), falloffExponent);
    if (falloff <= 0.0) return color;
    const float3 a = CasTap(uv, float2(-1.0, -1.0));
    const float3 b = CasTap(uv, float2( 0.0, -1.0));
    const float3 c = CasTap(uv, float2( 1.0, -1.0));
    const float3 d = CasTap(uv, float2(-1.0,  0.0));
    const float3 e = color.rgb;
    const float3 f = CasTap(uv, float2( 1.0,  0.0));
    const float3 g = CasTap(uv, float2(-1.0,  1.0));
    const float3 h = CasTap(uv, float2( 0.0,  1.0));
    const float3 i = CasTap(uv, float2( 1.0,  1.0));
    float3 mn = min(min(min(d, e), min(f, b)), h);
    float3 mx = max(max(max(d, e), max(f, b)), h);
    mn += min(min(min(mn, a), min(c, g)), i);
    mx += max(max(max(mx, a), max(c, g)), i);
    const float amp = sqrt(saturate(min(mn.g, 2.0 - mx.g) / max(mx.g, 1.0e-5)));
    const float peak = -1.0 / lerp(8.0, 5.0, saturate(TESR_SharpeningData.x));
    const float w = amp * peak;
    const float3 sharpened = saturate(((b + d + f + h) * w + e) / (1.0 + 4.0 * w));
    color.rgb = lerp(color.rgb, sharpened, falloff);
    return color;
}

float4 ContrastAdaptiveSharpening(VSOUT IN) : COLOR
{
    [branch] if (TESR_SharpeningData.w > 0.5) return CasSharpen(IN.UVCoord);   // (2026-11-13 CAS)
    // CAS Params
    float intensity = TESR_SharpeningData.x * 2; // Multiplied by two so it's more noticeable change
    float maxDepth = TESR_SharpeningData.z * 1000; // Multiplied by 1000 so the default values start at zero to one

    // Sample the rendered and reconstruct position from depth for depth falloff
    float4 color = tex2Dlod(TESR_RenderedBuffer, float4(IN.UVCoord, 0.0, 0.0));   // (2026-11-13: explicit lod, the same on these mip-less buffers: safe after the CAS branch)
    float depth = readDepthLod(IN.UVCoord);

    // Calculate the falloff factor using pow
    float falloffFactor = pow(saturate((maxDepth - depth) / maxDepth), falloffExponent);

    // Calculate the average color of the surrounding pixels
    float3 average = 0;
    float sum = 0;
    for (int x = -kernelSize / 2; x <= kernelSize / 2; x++)
    {
        for (int y = -kernelSize / 2; y <= kernelSize / 2; y++)
        {
            float weight = 1.0 - (abs(x) + abs(y)) / kernelSize; // simulate weights with Manhattan distance
            average += tex2Dlod(TESR_RenderedBuffer, float4(IN.UVCoord + float2(x, y) * TESR_ReciprocalResolution.xy, 0.0, 0.0)).rgb * weight;
            sum += weight;
        }
    }
    average /= sum;
    
    // Calculate the contrast between the current pixel and the average color
    float contrast = dot(abs(color.rgb - average), luma(color.rgb) / (luma(color.rgb) + 0.05));
    
    // Calculate the sharpening and lerp with fallofffactor
    color.rgb = lerp(color.rgb, color.rgb + (color.rgb - average) * saturate(contrast * intensity), falloffFactor);
    
    // Debug modes
    #if debugMode == 1
        return falloffFactor;
    #elif debugMode == 2
        return contrast * intensity;
    #elif debugMode == 3
        return float4(average, 1.0);   
    #endif
	
    return color;
}

technique
{
    pass
    {
        VertexShader = compile vs_3_0 FrameVS();
        PixelShader = compile ps_3_0 ContrastAdaptiveSharpening();
    }
}
