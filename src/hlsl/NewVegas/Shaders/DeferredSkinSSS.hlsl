// UNOFFICIAL 2026-11-15 SSS v2: the deferred skin's subsurface scattering (core/DeferredSkin.h, [Main.Main.Quality] DeferredSkinSSS 2 with
// [Shaders.Skin.SSS] Kernel 0; docs/next/FD-SKIN-RESULTS.md "SSS v2").
// CREDIT Conor (mrfury97): the screen-space skin scattering this builds on is his (SkinScattering, from his NVR testbed: the skin found in
// screen space, the highlights taken out before the blur and put back after, light divided by the albedo so the texture stays sharp, after
// Community Shaders' pre/post scatter); the separable kernel it replaces here is Jimenez & Gutierrez's (Separable SSS, 2012) with Community
// Shaders' kernel generator (GPL-3.0-or-later), still used with Kernel 1.
// The profile here is Christensen & Burley's normalized diffusion (Pixar, "Approximate Reflectance Profiles for Efficient Subsurface
// Scattering", 2015), from the paper's formulas: R(r) = (e^(-r/d) + e^(-r/3d)) / (8 pi d r), which integrates to 1 over the plane, one d per
// colour (red longest). It is sampled on a disc: the radii are drawn from the widest colour's (red's) distribution, CDF(r) = 1 - 1/4 e^(-r/d)
// - 3/4 e^(-r/3d), inverted on the CPU for evenly spaced u (DeferredSkin::SssTaps), each tap weighted per colour by R_c(r) / R_red(r) and the
// weights normalised by their sum (energy kept per colour whatever the taps found), the disc turned by the golden angle per tap and by a per-
// frame angle while TAA / FSR / DLSS resolve (SharedNoise; still otherwise).
// Run after the deferred light passes, in linear light, before LinearScene encodes (the frame then holds every lamp's light: all of it
// diffuses), on the deferred skin's pixels only (COLOR3.a 3.5+, model 6): hair, gear and anything not skin neither give nor take light.
//   SSS_PREP: per skin pixel the light that diffuses, L = (frame - highlights x keep) x participation / albedo^AlbedoDetail, and the view
//             z in a; 0 elsewhere (the target is cleared)
//   SSS_BLUR: the disc over L (depth-aware: a tap counts only near the centre's depth, by its radius), back into the frame:
//             highlights x keep + albedo^detail x blurred L (+ the dark texels' own light), written over the skin pixels (blend off)

#include "includes/Helpers.hlsl"
#include "includes/DeferredPixel.hlsl"

#define SSS_TAPS 24

float4 SSS_View : register(c0);	// xy 1 / target size, z pixels per world unit at view z 1 (height / (2 tan(fov y / 2))), w the disc's angle this frame
float4 SSS_Ctrl : register(c1);	// x the reference scatter distance d (red, world units), y DepthFollow, z AlbedoDetail, w 1 = the exact view z on s5
float4 SSS_Taps[SSS_TAPS] : register(c2);	// x the tap's radius / d_red, yzw its weight per colour (R_c / R_red), from DeferredSkin::SssTaps

#ifdef SSS_PREP
sampler2D SSS_Frame    : register(s0);	// the frame's copy, linear
sampler2D SSS_Albedo   : register(s1);	// COLOR1: rgb albedo, a the code (keep)
sampler2D SSS_Spec     : register(s2);	// the skin's highlight target (raw linear)
sampler2D SSS_Normals  : register(s3);	// COLOR3: b the distance, a the skin code
sampler2D SSS_Material : register(s4);	// COLOR2: r the model
sampler2D SSS_LinearZ  : register(s5);	// DeferredDepth's exact linear view z (R32F) while SSS_Ctrl.w is 1

float3 Participation(float3 a) { return smoothstep(0.01f, 0.04f, a); }	// (Conor's / CS's: dark texels take no part)
float3 AlbedoFactor(float3 a) { return pow(max(a, 1.0e-4f), SSS_Ctrl.z); }

float4 main(float2 uv : TEXCOORD0) : COLOR0 {
    const float4 uv4 = float4(uv, 0.0f, 0.0f);
    const float4 n = tex2Dlod(SSS_Normals, uv4);
    const float4 m = tex2Dlod(SSS_Material, uv4);
    clip(n.a > 3.5f && abs(FDModel(m.r) - 6.0f) < 0.5f ? 1.0f : -1.0f);
    const float4 a = tex2Dlod(SSS_Albedo, uv4);
    const float keep = saturate(FDAddedLightKeep(a.a));
    const float3 diffuse = max(tex2Dlod(SSS_Frame, uv4).rgb - tex2Dlod(SSS_Spec, uv4).rgb * keep, 0.0f);
    const float z = SSS_Ctrl.w > 0.5f ? tex2Dlod(SSS_LinearZ, uv4).x : n.b;
    return float4(min(diffuse * Participation(a.rgb) / AlbedoFactor(a.rgb), 64.0f), max(z, 1.0e-3f));
}
#else	// SSS_BLUR
sampler2D SSS_Light  : register(s0);	// SSS_PREP's target
sampler2D SSS_Frame  : register(s1);	// the frame's copy, linear
sampler2D SSS_Albedo : register(s2);
sampler2D SSS_Spec   : register(s3);

float3 Participation(float3 a) { return smoothstep(0.01f, 0.04f, a); }
float3 AlbedoFactor(float3 a) { return pow(max(a, 1.0e-4f), SSS_Ctrl.z); }

float4 main(float2 uv : TEXCOORD0) : COLOR0 {
    const float4 c = tex2Dlod(SSS_Light, float4(uv, 0.0f, 0.0f));
    clip(c.a - 1.0e-4f);	// not deferred skin
    const float z0 = c.a;
    const float pxPerD = SSS_Ctrl.x * SSS_View.z / z0;	// the reference distance d in pixels here
    float3 sum = 0.0f, weight = 0.0f;
    [unroll] for (int i = 0; i < SSS_TAPS; i++) {
        const float4 tap = SSS_Taps[i];
        float s, co;
        sincos(SSS_View.w + 2.39996323f * (float)i, s, co);
        const float2 at = uv + float2(co, s) * (tap.x * pxPerD) * SSS_View.xy;
        const float4 t = tex2Dlod(SSS_Light, float4(at, 0.0f, 0.0f));
        // depth-aware: the tap is the same surface only within about its own radius in depth (DepthFollow stricter); not skin: a = 0
        const float reach = tap.x * SSS_Ctrl.x * 2.0f / max(SSS_Ctrl.y, 0.1f) + 0.05f;
        const float3 w = tap.yzw * (t.a > 0.0f ? saturate(1.0f - abs(t.a - z0) / reach) : 0.0f);
        sum += t.rgb * w;
        weight += w;
    }
    const float3 blurred = weight.x > 0.0f ? sum / max(weight, 1.0e-6f) : c.rgb;
    const float4 a = tex2Dlod(SSS_Albedo, float4(uv, 0.0f, 0.0f));
    const float keep = saturate(FDAddedLightKeep(a.a));
    const float3 spec = tex2Dlod(SSS_Spec, float4(uv, 0.0f, 0.0f)).rgb * keep;
    const float3 frame = tex2Dlod(SSS_Frame, float4(uv, 0.0f, 0.0f)).rgb;
    const float3 diffuse = max(frame - spec, 0.0f);
    const float3 part = Participation(a.rgb);
    // the participating share of the light takes the blurred value; the dark texels keep their own
    return float4(spec + diffuse * (1.0f - part) + blurred * AlbedoFactor(a.rgb), 1.0f);
}
#endif
